// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICanonicalIdentity} from "./interfaces/ICanonicalIdentity.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IReputationSink} from "./interfaces/IReputationSink.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {PaymentRouterAdmin} from "./payment/PaymentRouterAdmin.sol";

/// @notice Payment-rail-agnostic commission split, payment ledger, deposit
///         reservation, and provider refund entry point. Adapters handle rail
///         mechanics; this contract enforces service references, catalog
///         membership, payout ownership, and immutable payer destinations.
contract PaymentRouter is PaymentRouterAdmin {
    using SafeERC20 for IERC20;

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
        identity = ICanonicalIdentity(_identity);
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
        address buyerWallet,
        uint256 providerAgentId,
        bytes32 serviceId
    ) external onlyAdapter nonReentrant returns (uint256 paymentId) {
        paymentId = _settle(token, amount, serviceRef, buyerAgentId, buyerWallet, providerAgentId, serviceId);
    }

    /// @inheritdoc IPaymentRouter
    function reserveDeposit(address token, bytes32 depositId, uint256 amount, address refundTo)
        external
        onlyAdapter
        nonReentrant
    {
        require(amount > 0, "zero amount");
        require(acceptedTokens[token], "token not accepted");
        require(refundTo != address(0), "zero refund address");

        bytes32 key = _reservationKey(msg.sender, depositId);
        require(_reservations[key].amount == 0, "deposit already reserved");

        uint256 newReserved = _reservedBalances[token] + amount;
        require(IERC20(token).balanceOf(address(this)) >= newReserved, "deposit not funded");

        _reservedBalances[token] = newReserved;
        _reservations[key] = Reservation({token: token, refundTo: refundTo, amount: amount});

        emit DepositReserved(msg.sender, depositId, token, refundTo, amount);
    }

    /// @inheritdoc IPaymentRouter
    function settleReserved(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 buyerAgentId,
        address buyerWallet,
        uint256 providerAgentId,
        bytes32 serviceId,
        bytes32 depositId
    ) external onlyAdapter nonReentrant returns (uint256 paymentId) {
        bytes32 key = _reservationKey(msg.sender, depositId);
        Reservation memory reservation = _reservations[key];
        require(reservation.amount > 0, "deposit not reserved");
        require(reservation.token == token && reservation.amount == amount, "deposit mismatch");

        delete _reservations[key];
        _reservedBalances[token] -= amount;

        paymentId = _settle(token, amount, serviceRef, buyerAgentId, buyerWallet, providerAgentId, serviceId);
    }

    /// @inheritdoc IPaymentRouter
    function refundReservedDeposit(address token, bytes32 depositId) external onlyAdapter nonReentrant {
        bytes32 key = _reservationKey(msg.sender, depositId);
        Reservation memory reservation = _reservations[key];
        require(reservation.amount > 0, "deposit not reserved");
        require(reservation.token == token, "deposit mismatch");

        delete _reservations[key];
        _reservedBalances[token] -= reservation.amount;
        IERC20(token).safeTransfer(reservation.refundTo, reservation.amount);

        emit ReservedDepositRefunded(msg.sender, depositId, token, reservation.refundTo, reservation.amount);
    }

    function _settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 buyerAgentId,
        address buyerWallet,
        uint256 providerAgentId,
        bytes32 serviceId
    ) internal returns (uint256 paymentId) {
        require(amount > 0, "zero amount");
        require(acceptedTokens[token], "token not accepted");
        require(!_usedServiceRefs[serviceRef], "serviceRef used");
        require(buyerWallet != address(0), "zero buyer wallet");

        // Prevent an adapter from caching an unrelated refund destination.
        require(
            buyerWallet == identity.getAgentWallet(buyerAgentId) || buyerWallet == identity.ownerOf(buyerAgentId),
            "buyer wallet mismatch"
        );

        require(registry.getProvider(providerAgentId).isActive, "provider not active");

        IServiceRegistry.Service memory svc = serviceRegistry.getService(serviceId);
        require(svc.providerAgentId == providerAgentId, "service/provider mismatch");
        require(svc.active, "service not active");

        // An override is valid only while the NFT owner that authorized it
        // still owns the provider agent.
        address payee;
        if (svc.serviceWallet != address(0) && svc.serviceWalletOwner == identity.ownerOf(providerAgentId)) {
            payee = svc.serviceWallet;
        }
        if (payee == address(0)) {
            payee = identity.getAgentWallet(providerAgentId);
        }
        require(payee != address(0), "no payee wallet");

        // Reserved deposits cannot fund unrelated settlements.
        require(IERC20(token).balanceOf(address(this)) >= _reservedBalances[token] + amount, "router under-funded");

        // Mark used before token or reputation calls.
        _usedServiceRefs[serviceRef] = true;

        uint256 commission = (amount * commissionBps) / 10000;
        uint256 providerAmount = amount - commission;

        IERC20(token).safeTransfer(payee, providerAmount);
        if (commission > 0) {
            IERC20(token).safeTransfer(treasury, commission);
        }

        paymentId = nextPaymentId++;
        _payments[paymentId] = PaymentRecord({
            buyerAgentId: buyerAgentId,
            providerAgentId: providerAgentId,
            serviceId: serviceId,
            token: token,
            amount: amount,
            cachedBuyerWallet: buyerWallet,
            serviceRef: serviceRef,
            paidAt: block.timestamp
        });

        emit PaymentSettled(
            paymentId, serviceRef, serviceId, buyerAgentId, providerAgentId, token, amount, providerAmount, commission
        );

        address sink = reputationStorage;
        if (sink != address(0)) {
            IReputationSink(sink).recordPayment(paymentId);
        }
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

        // Auth surface mirrors ServiceRegistry / ValidationRegistry: NFT
        // owner OR operator OR per-token approved OR the provider's CURRENT
        // agentWallet on the canonical registry. Rotated-out wallets fail
        // because the live agentWallet is read at call time.
        require(
            LibAgentAuth.isAuthorizedOrAgentWallet(identity, rec.providerAgentId, msg.sender),
            "not authorized for provider"
        );

        uint256 already = _refundedAmount[paymentId];
        uint256 newTotal = already + amountToBuyer;
        require(newTotal <= rec.amount, "exceeds refundable amount");

        // Return funds to the wallet that paid. A later NFT transfer or
        // agentWallet rotation must not redirect a historical refund.
        address dest = rec.cachedBuyerWallet;
        require(dest != address(0), "no refund destination");

        _refundedAmount[paymentId] = newTotal;

        // Direct caller → buyer transfer. Caller must have approved this
        // router for at least amountToBuyer. Single hop saves gas and
        // nonReentrant already protects against any token hook misbehavior.
        IERC20(rec.token).safeTransferFrom(msg.sender, dest, amountToBuyer);

        emit Refunded(paymentId, amountToBuyer, newTotal);

        // Keep the payment and reputation records atomic. If the configured
        // sink rejects the update, all state and token movement revert.
        address sink = reputationStorage;
        if (sink != address(0)) {
            IReputationSink(sink).recordRefund(paymentId, amountToBuyer);
        }
    }
}
