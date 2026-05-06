// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// NOTE: OZ v5 removed ReentrancyGuardUpgradeable. The non-upgradeable ReentrancyGuard is
// marked @custom:stateless (uses a storage slot, no initializer) and is safe behind UUPS proxies.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";

/// @dev Minimal reputation sink. Decoupled from the router: admin may wire
///      this on or leave it unset, and a failed reputation call never
///      reverts the refund (reputation is a tracking sidecar, not consensus).
interface IReputationRefundSink {
    function recordRefund(uint256 paymentId, uint256 amountToBuyer) external;
}

/// @notice Payment-rail-agnostic router. Whitelisted adapter contracts are
///         responsible for the specifics of how funds arrive at the router
///         (EIP-3009, EIP-2612 permit, plain approve, or future rails). The
///         router only handles the shared invariants: commission split,
///         serviceRef uniqueness, per-payment records, and provider-initiated
///         refunds.
///
/// Design notes:
///   * `settle` enforces serviceRef single-use — even though adapters may
///     also add their own replay protection (e.g. EIP-3009 nonces), the
///     contract-level uniqueness is the final line of defense.
///   * The PaymentRecord caches the buyer's wallet at settle time. Refund
///     prefers the LIVE agentWallet (via IdentityRegistry) and only falls
///     back to the cached wallet if the buyer's agent has unset their
///     wallet. This honors ERC-8004 wallet rotation while keeping refunds
///     possible if the buyer abandons the wallet without updating.
///   * Refunds are partial, cumulative, and have no expiration. Total per
///     paymentId is capped at the original amount. The provider is the only
///     party who can initiate a refund — buyer recourse is reputation, not
///     on-chain reclaim (per whitepaper §7).
contract PaymentRouter is Initializable, UUPSUpgradeable, ReentrancyGuard, IPaymentRouter {
    using SafeERC20 for IERC20;

    // ── Storage ──────────────────────────────────────────────────────
    address public admin;
    address public pendingAdmin;
    address public treasury;
    IdentityRegistry public identity;
    IProviderRegistry public registry;
    uint256 public commissionBps;

    uint256 public nextPaymentId;

    mapping(uint256 => PaymentRecord) internal _payments;
    mapping(bytes32 => bool) private _usedServiceRefs;

    /// @notice Whitelist of adapter contracts allowed to call `settle`.
    mapping(address => bool) public adapters;

    /// @notice Whitelist of ERC-20 tokens accepted for payments. Adapters
    ///         should pre-check this before pulling funds to avoid wasted
    ///         gas, and the router rejects at `settle` regardless.
    mapping(address => bool) public acceptedTokens;

    /// @notice Cumulative refunded amount per paymentId. Capped at the
    ///         original amount; checked on every refund.
    mapping(uint256 => uint256) internal _refundedAmount;

    /// @notice Optional ReputationStorage hook. When set, refunds are
    ///         mirrored into the reputation layer so reviewers can see
    ///         provider goodwill alongside outcome/confirmation data.
    address public reputationStorage;

    // ── Events ───────────────────────────────────────────────────────
    event PaymentSettled(
        uint256 indexed paymentId,
        bytes32 indexed serviceRef,
        uint256 buyerAgentId,
        uint256 providerAgentId,
        address token,
        uint256 totalAmount,
        uint256 providerAmount,
        uint256 commission
    );

    event Refunded(uint256 indexed paymentId, uint256 amountToBuyer, uint256 cumulativeRefunded);
    event AdapterSet(address indexed adapter, bool allowed);
    event AcceptedTokenSet(address indexed token, bool allowed);
    event CommissionUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event ReputationStorageUpdated(address indexed oldStorage, address indexed newStorage);

    // ── Modifiers ────────────────────────────────────────────────────
    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyAdapter() {
        require(adapters[msg.sender], "not adapter");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identity, address _registry, address _treasury, uint256 _commissionBps, address _admin)
        external
        initializer
    {
        require(_identity != address(0), "zero identity");
        require(_registry != address(0), "zero registry");
        require(_treasury != address(0), "zero treasury");
        require(_admin != address(0), "zero admin");
        require(_commissionBps <= 10000, "commission too high");
        identity = IdentityRegistry(_identity);
        registry = IProviderRegistry(_registry);
        treasury = _treasury;
        commissionBps = _commissionBps;
        admin = _admin;
        nextPaymentId = 1;
    }

    // ── Settlement (adapter-only) ────────────────────────────────────

    /// @inheritdoc IPaymentRouter
    function settle(address token, uint256 amount, bytes32 serviceRef, uint256 buyerAgentId, uint256 providerAgentId)
        external
        onlyAdapter
        nonReentrant
        returns (uint256 paymentId)
    {
        require(amount > 0, "zero amount");
        require(acceptedTokens[token], "token not accepted");
        require(!_usedServiceRefs[serviceRef], "serviceRef used");
        require(buyerAgentId != 0, "buyer has no agent");

        IProviderRegistry.Provider memory provider = registry.getProvider(providerAgentId);
        require(provider.isActive, "provider not active");

        // Pay the LIVE agentWallet from IdentityRegistry, not the (potentially
        // stale) walletAddress recorded at provider registration time. Identity
        // transfers and wallet rotations both update this; ProviderRegistry
        // does not auto-sync. Fall back to the registry's wallet only if the
        // provider has unset their agentWallet (so payments don't silently
        // re-route to a freshly-cleared slot).
        address payee = identity.getAgentWallet(providerAgentId);
        if (payee == address(0)) {
            payee = provider.walletAddress;
        }
        require(payee != address(0), "no provider payee");

        // Defense-in-depth: the adapter is supposed to have transferred
        // `amount` of `token` into this contract before calling settle.
        // Verify the contract actually holds at least that much before paying
        // out, so a buggy adapter cannot drain pre-existing balance for a
        // settle it never funded.
        require(IERC20(token).balanceOf(address(this)) >= amount, "router under-funded");

        // Mark serviceRef used before any external calls to avoid reentrant
        // re-spends via a malicious token.
        _usedServiceRefs[serviceRef] = true;

        uint256 commission = (amount * commissionBps) / 10000;
        uint256 providerAmount = amount - commission;

        IERC20(token).safeTransfer(payee, providerAmount);
        if (commission > 0) {
            IERC20(token).safeTransfer(treasury, commission);
        }

        // Cache the buyer's wallet as a refund fallback. If the agent unsets
        // their wallet later, refunds can still land here as a best-effort.
        address cachedBuyer = identity.getAgentWallet(buyerAgentId);

        paymentId = nextPaymentId++;
        _payments[paymentId] = PaymentRecord({
            buyerAgentId: buyerAgentId,
            providerAgentId: providerAgentId,
            token: token,
            amount: amount,
            cachedBuyerWallet: cachedBuyer,
            serviceRef: serviceRef
        });

        emit PaymentSettled(
            paymentId, serviceRef, buyerAgentId, providerAgentId, token, amount, providerAmount, commission
        );
    }

    // ── Provider-initiated refund ────────────────────────────────────

    /// @inheritdoc IPaymentRouter
    function refund(uint256 paymentId, uint256 amountToBuyer) external nonReentrant {
        require(amountToBuyer > 0, "zero refund");
        PaymentRecord memory rec = _payments[paymentId];
        require(rec.amount > 0, "payment not found");

        // Only the CURRENT agent wallet of the original provider may refund.
        // If the provider rotated their wallet, the new wallet is authorized;
        // the old one is not. Using agentOfWallet keeps this live-resolved.
        uint256 callerAgentId = identity.agentOfWallet(msg.sender);
        require(callerAgentId == rec.providerAgentId, "not provider for payment");

        uint256 already = _refundedAmount[paymentId];
        uint256 newTotal = already + amountToBuyer;
        require(newTotal <= rec.amount, "exceeds refundable amount");

        // Resolve the refund destination. Prefer the buyer's CURRENT agent
        // wallet (honors wallet rotation); fall back to the cached original
        // wallet if the agent has unset their wallet.
        address dest = identity.getAgentWallet(rec.buyerAgentId);
        if (dest == address(0)) {
            dest = rec.cachedBuyerWallet;
        }
        require(dest != address(0), "no refund destination");

        _refundedAmount[paymentId] = newTotal;

        // Direct provider → buyer transfer. The provider must have pre-approved
        // the router. Single hop saves gas and the nonReentrant modifier
        // already protects against any token hook misbehavior.
        IERC20(rec.token).safeTransferFrom(msg.sender, dest, amountToBuyer);

        emit Refunded(paymentId, amountToBuyer, newTotal);

        // Best-effort mirror into the reputation storage. Swallow any
        // revert so reputation issues don't block a refund — the canonical
        // record is in the router's own _refundedAmount mapping, and
        // PaymentRouter.Refunded is the authoritative event.
        address sink = reputationStorage;
        if (sink != address(0)) {
            try IReputationRefundSink(sink).recordRefund(paymentId, amountToBuyer) {} catch {}
        }
    }

    // ── Views ────────────────────────────────────────────────────────

    function quoteCommission(uint256 amount) external view returns (uint256 commission, uint256 providerAmount) {
        commission = (amount * commissionBps) / 10000;
        providerAmount = amount - commission;
    }

    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory) {
        require(_payments[paymentId].amount > 0, "payment not found");
        return _payments[paymentId];
    }

    function refundedAmount(uint256 paymentId) external view returns (uint256) {
        return _refundedAmount[paymentId];
    }

    function serviceRefUsed(bytes32 serviceRef) external view returns (bool) {
        return _usedServiceRefs[serviceRef];
    }

    function isAdapter(address adapter) external view returns (bool) {
        return adapters[adapter];
    }

    function isAcceptedToken(address token) external view returns (bool) {
        return acceptedTokens[token];
    }

    // ── Admin ────────────────────────────────────────────────────────

    function setAdapter(address adapter, bool allowed) external onlyAdmin {
        require(adapter != address(0), "zero adapter");
        adapters[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function setAcceptedToken(address token, bool allowed) external onlyAdmin {
        require(token != address(0), "zero token");
        acceptedTokens[token] = allowed;
        emit AcceptedTokenSet(token, allowed);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), "zero treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setReputationStorage(address newStorage) external onlyAdmin {
        address oldStorage = reputationStorage;
        reputationStorage = newStorage;
        emit ReputationStorageUpdated(oldStorage, newStorage);
    }

    function setCommissionBps(uint256 newBps) external onlyAdmin {
        require(newBps <= 10000, "commission too high");
        uint256 oldBps = commissionBps;
        commissionBps = newBps;
        emit CommissionUpdated(oldBps, newBps);
    }

    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
