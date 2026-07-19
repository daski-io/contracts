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
import {PaymentRouterViews} from "./payment/PaymentRouterViews.sol";

/// @notice Payment-rail-agnostic settlement and provider refund entry point.
///         Adapters move funds into the router; this contract validates the
///         catalog route, splits funds, and stores immutable counterparties.
contract PaymentRouter is PaymentRouterAdmin, PaymentRouterViews {
    using SafeERC20 for IERC20;

    struct Settlement {
        address token;
        uint256 amount;
        bytes32 serviceRef;
        uint256 buyerAgentId;
        address buyerWallet;
        uint256 providerAgentId;
        bytes32 serviceId;
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
        identity = ICanonicalIdentity(_identity);
        registry = IProviderRegistry(_registry);
        serviceRegistry = IServiceRegistry(_serviceRegistry);
        treasury = _treasury;
        commissionBps = _commissionBps;
        nextPaymentId = 1;
    }

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
        Settlement memory request = Settlement({
            token: token,
            amount: amount,
            serviceRef: serviceRef,
            buyerAgentId: buyerAgentId,
            buyerWallet: buyerWallet,
            providerAgentId: providerAgentId,
            serviceId: serviceId
        });
        paymentId = _settle(request);
    }

    function _settle(Settlement memory request) internal returns (uint256 paymentId) {
        require(request.amount > 0, "zero amount");
        require(acceptedTokens[request.token], "token not accepted");
        require(!_usedServiceRefs[request.serviceRef], "serviceRef used");
        require(request.buyerWallet != address(0), "zero buyer wallet");
        require(reputationStorage.code.length > 0, "reputation not configured");
        require(
            request.buyerWallet == identity.getAgentWallet(request.buyerAgentId)
                || request.buyerWallet == identity.ownerOf(request.buyerAgentId),
            "buyer wallet mismatch"
        );

        (address payee, address providerOwner, address providerWallet) = _providerContext(request);
        require(IERC20(request.token).balanceOf(address(this)) >= request.amount, "router under-funded");

        _usedServiceRefs[request.serviceRef] = true;

        uint256 commission = (request.amount * commissionBps) / 10000;
        uint256 providerAmount = request.amount - commission;
        IERC20(request.token).safeTransfer(payee, providerAmount);
        if (commission > 0) {
            IERC20(request.token).safeTransfer(treasury, commission);
        }

        paymentId = nextPaymentId++;
        _payments[paymentId] = PaymentRecord({
            buyerAgentId: request.buyerAgentId,
            providerAgentId: request.providerAgentId,
            serviceId: request.serviceId,
            token: request.token,
            amount: request.amount,
            cachedBuyerWallet: request.buyerWallet,
            cachedProviderOwner: providerOwner,
            cachedProviderWallet: providerWallet,
            serviceRef: request.serviceRef,
            paidAt: block.timestamp
        });

        emit PaymentSettled(
            paymentId,
            request.serviceRef,
            request.serviceId,
            request.buyerAgentId,
            request.providerAgentId,
            request.token,
            request.amount,
            providerAmount,
            commission
        );

        IReputationSink(reputationStorage).recordPayment(paymentId);
    }

    function _providerContext(Settlement memory request)
        internal
        view
        returns (address payee, address providerOwner, address providerWallet)
    {
        require(registry.getProvider(request.providerAgentId).isActive, "provider not active");

        IServiceRegistry.Service memory service = serviceRegistry.getService(request.serviceId);
        require(service.providerAgentId == request.providerAgentId, "service/provider mismatch");
        require(service.active, "service not active");

        providerOwner = identity.ownerOf(request.providerAgentId);
        providerWallet = identity.getAgentWallet(request.providerAgentId);
        if (service.serviceWallet != address(0) && service.serviceWalletOwner == providerOwner) {
            payee = service.serviceWallet;
        } else {
            payee = providerWallet;
        }
        require(payee != address(0), "no payee wallet");
    }

    /// @inheritdoc IPaymentRouter
    /// @dev The authorized caller funds the refund. Historical refunds always
    ///      return to the wallet that made the original payment.
    function refund(uint256 paymentId, uint256 amountToBuyer) external nonReentrant {
        require(amountToBuyer > 0, "zero refund");
        PaymentRecord memory record = _payments[paymentId];
        require(record.amount > 0, "payment not found");
        require(
            LibAgentAuth.isAuthorizedOrAgentWallet(identity, record.providerAgentId, msg.sender),
            "not authorized for provider"
        );

        uint256 cumulative = _refundedAmount[paymentId] + amountToBuyer;
        require(cumulative <= record.amount, "exceeds refundable amount");
        require(record.cachedBuyerWallet != address(0), "no refund destination");
        _refundedAmount[paymentId] = cumulative;

        IERC20(record.token).safeTransferFrom(msg.sender, record.cachedBuyerWallet, amountToBuyer);
        emit Refunded(paymentId, amountToBuyer, cumulative);
        IReputationSink(reputationStorage).recordRefund(paymentId, amountToBuyer);
    }
}
