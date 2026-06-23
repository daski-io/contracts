// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// We deliberately use the non-upgradeable ReentrancyGuard. In OZ v5 it is
// marked @custom:stateless (no initializer required; uses a fixed namespaced-storage slot
// per ERC-7201) and is safe behind UUPS proxies — the proxy's storage at that slot
// defaults to 0, which the modifier treats as NOT_ENTERED.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";
import {IReputationRefundSink} from "./interfaces/IReputationRefundSink.sol";

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
///   * `settle` validates the (provider, service) pair against ServiceRegistry.
///     The serviceId is recorded on the PaymentRecord so reputation queries
///     and refund mirrors can attribute outcomes per-service.
///   * Payee resolution: service.serviceWallet if non-zero, else the
///     provider's live ERC-8004 agentWallet. Per-service wallets let
///     providers isolate accounting (regulated vs unregulated, separate
///     jurisdictions, etc.). When unset (the common case) the existing
///     "pay live agentWallet" semantics apply.
///   * The PaymentRecord caches the buyer's wallet at settle time. Refund
///     prefers the LIVE agentWallet (via IdentityRegistry) and only falls
///     back to the cached wallet if the buyer's agent has unset their
///     wallet. This honors ERC-8004 wallet rotation while keeping refunds
///     possible if the buyer abandons the wallet without updating.
///   * Refunds are partial, cumulative, and have no expiration. Total per
///     paymentId is capped at the original amount. Authorized refund callers
///     are: provider NFT owner, ERC-721 operators (isApprovedForAll),
///     per-token approved spender (getApproved), and the live agentWallet.
///     Source of funds is `msg.sender` via safeTransferFrom — a malicious
///     or compromised operator can only burn THEIR OWN approved balance,
///     never drain the provider's agentWallet. Worst-case abuse is
///     self-griefing, not theft from the provider.
contract PaymentRouter is Admin2StepUpgradeable, ReentrancyGuard, IPaymentRouter {
    using SafeERC20 for IERC20;

    // ── Storage ──────────────────────────────────────────────────────
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

    /// @notice ServiceRegistry. settle() validates the (provider, service)
    ///         pair against this and reads the per-service payee override.
    IServiceRegistry public serviceRegistry;

    // ── Events ───────────────────────────────────────────────────────
    event PaymentSettled(
        uint256 indexed paymentId,
        bytes32 indexed serviceRef,
        bytes32 indexed serviceId,
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
    event ServiceRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // ── Modifiers ────────────────────────────────────────────────────
    modifier onlyAdapter() {
        require(adapters[msg.sender], "not adapter");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _identity,
        address _registry,
        address _serviceRegistry,
        address _treasury,
        uint256 _commissionBps,
        address _admin
    ) external initializer {
        require(_identity != address(0), "zero identity");
        require(_registry != address(0), "zero registry");
        require(_serviceRegistry != address(0), "zero service registry");
        require(_treasury != address(0), "zero treasury");
        require(_commissionBps <= 10000, "commission too high");
        __Admin2Step_init(_admin);
        identity = IdentityRegistry(_identity);
        registry = IProviderRegistry(_registry);
        serviceRegistry = IServiceRegistry(_serviceRegistry);
        treasury = _treasury;
        commissionBps = _commissionBps;
        nextPaymentId = 1;
    }

    // ── Settlement (adapter-only) ────────────────────────────────────

    /// @inheritdoc IPaymentRouter
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 buyerAgentId,
        uint256 providerAgentId,
        bytes32 serviceId
    ) external onlyAdapter nonReentrant returns (uint256 paymentId) {
        require(amount > 0, "zero amount");
        require(acceptedTokens[token], "token not accepted");
        require(!_usedServiceRefs[serviceRef], "serviceRef used");
        require(buyerAgentId != 0, "buyer has no agent");

        require(registry.getProvider(providerAgentId).isActive, "provider not active");

        // Validate service belongs to this provider and is active. Reading
        // through ServiceRegistry binds the payment to a specific catalog
        // entry, which is what reputation queries key on downstream.
        IServiceRegistry.Service memory svc = serviceRegistry.getService(serviceId);
        require(svc.providerAgentId == providerAgentId, "service/provider mismatch");
        require(svc.active, "service not active");

        // Payee resolution: per-service override wins, else fall back to the
        // provider's LIVE agentWallet from IdentityRegistry. If both are
        // unset, reject — per ERC-8004, agentWallet "must be re-verified by
        // the new owner" before payments resume after an NFT transfer.
        address payee = svc.serviceWallet;
        if (payee == address(0)) {
            payee = identity.getAgentWallet(providerAgentId);
        }
        require(payee != address(0), "no payee wallet");

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
            serviceId: serviceId,
            token: token,
            amount: amount,
            cachedBuyerWallet: cachedBuyer,
            serviceRef: serviceRef,
            paidAt: block.timestamp
        });

        emit PaymentSettled(
            paymentId, serviceRef, serviceId, buyerAgentId, providerAgentId, token, amount, providerAmount, commission
        );
    }

    // ── Provider-initiated refund ────────────────────────────────────

    /// @inheritdoc IPaymentRouter
    /// @dev Authorization is decoupled from the source of funds. Authorized
    ///      callers (NFT owner, operator, approved spender, agentWallet)
    ///      issue refunds that pull from THEIR OWN approved USDC balance via
    ///      safeTransferFrom — they cannot drain the provider's agentWallet.
    ///      Worst-case abuse by a compromised operator is self-griefing
    ///      (burning their own USDC to fake a refund), not theft.
    function refund(uint256 paymentId, uint256 amountToBuyer) external nonReentrant {
        require(amountToBuyer > 0, "zero refund");
        PaymentRecord memory rec = _payments[paymentId];
        require(rec.amount > 0, "payment not found");

        // Auth surface mirrors IdentityRegistry / ReputationRegistry /
        // ValidationRegistry: NFT owner OR operator OR per-token approved
        // OR the provider's CURRENT agentWallet (back-compat). Rotated-out
        // wallets fail because agentOfWallet resolves live.
        address provOwner = identity.ownerOf(rec.providerAgentId);
        require(
            msg.sender == provOwner || identity.isApprovedForAll(provOwner, msg.sender)
                || identity.getApproved(rec.providerAgentId) == msg.sender
                || identity.agentOfWallet(msg.sender) == rec.providerAgentId,
            "not authorized for provider"
        );

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

        // Direct caller → buyer transfer. Caller must have approved this
        // router for at least amountToBuyer. Single hop saves gas and
        // nonReentrant already protects against any token hook misbehavior.
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

    function setServiceRegistry(address newRegistry) external onlyAdmin {
        require(newRegistry != address(0), "zero service registry");
        address old = address(serviceRegistry);
        serviceRegistry = IServiceRegistry(newRegistry);
        emit ServiceRegistryUpdated(old, newRegistry);
    }

    function setCommissionBps(uint256 newBps) external onlyAdmin {
        require(newBps <= 10000, "commission too high");
        uint256 oldBps = commissionBps;
        commissionBps = newBps;
        emit CommissionUpdated(oldBps, newBps);
    }

    /// @notice Admin rescue for tokens accidentally sent to the router.
    ///         Restricted to non-accepted tokens because accepted tokens
    ///         flow through the router transiently during settle (in and
    ///         out in the same tx, guarded by nonReentrant) — at-rest
    ///         balance is always zero for them. To rescue an accepted
    ///         token (e.g. someone misrouted USDC here), the admin must
    ///         temporarily de-list it via setAcceptedToken(false), call
    ///         this, then re-list. The unlisting also halts new settles
    ///         for that token, so the rescue cannot race a settle.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "zero to");
        require(!acceptedTokens[address(token)], "accepted token");
        token.safeTransfer(to, amount);
        emit ERC20Rescued(address(token), to, amount);
    }

    uint256[50] private __gap;
}
