// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ICanonicalIdentity} from "./interfaces/ICanonicalIdentity.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IReputationSink} from "./interfaces/IReputationSink.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {PaymentRouterAdmin} from "./payment/PaymentRouterAdmin.sol";
import {PaymentRouterViews} from "./payment/PaymentRouterViews.sol";
import {PaymentRouterSanctions} from "./payment/PaymentRouterSanctions.sol";
import {LibReputationEligibility} from "./payment/LibReputationEligibility.sol";

/// @notice Payment-rail-agnostic settlement and provider refund entry point.
///         Validates catalog routes, splits funds, and stores counterparties.
contract PaymentRouter is PaymentRouterAdmin, PaymentRouterViews, PaymentRouterSanctions {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

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
        address _sanctionsOracle,
        address _admin
    ) external initializer {
        require(_identity != address(0), "zero identity");
        require(_registry != address(0), "zero registry");
        require(_serviceRegistry != address(0), "zero service registry");
        require(_treasury != address(0), "zero treasury");
        require(_commissionBps <= 10000, "commission too high");
        __Admin2Step_init(_admin, _sanctionsOracle);
        identity = ICanonicalIdentity(_identity);
        registry = IProviderRegistry(_registry);
        serviceRegistry = IServiceRegistry(_serviceRegistry);
        _requireNotSanctioned(_treasury);
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
        require(_acceptedTokens.contains(request.token), "token not accepted");
        bytes32 paymentKey =
            _paymentKey(request.buyerAgentId, request.providerAgentId, request.serviceId, request.serviceRef);
        require(!_usedPaymentKeys[paymentKey], "payment key used");
        require(request.buyerWallet != address(0), "zero buyer wallet");
        address buyerAgentWallet = identity.getAgentWallet(request.buyerAgentId);
        address buyerOwner = identity.ownerOf(request.buyerAgentId);
        require(request.buyerWallet == buyerAgentWallet || request.buyerWallet == buyerOwner, "buyer wallet mismatch");

        (address payee, address providerOwner, address providerWallet) = _providerContext(request);
        uint256 commission = (request.amount * commissionBps) / 10000;
        _requireSettlementParticipantsAllowed(
            request.buyerWallet, buyerOwner, buyerAgentWallet, providerOwner, providerWallet, payee, commission
        );
        bool reputationEligible = _isReputationEligible(
            request, commission, buyerOwner, buyerAgentWallet, payee, providerOwner, providerWallet
        );
        // Adapters are trusted to have delivered `amount` to the router within
        // this transaction, and accepted tokens must not be fee-on-transfer:
        // the balance check proves the router is funded, not that THIS call
        // funded it.
        require(IERC20(request.token).balanceOf(address(this)) >= request.amount, "router under-funded");

        _usedPaymentKeys[paymentKey] = true;

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
            paidAt: block.timestamp,
            reputationEligible: reputationEligible
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

        _attemptReputationSync(paymentId);
    }

    function _providerContext(Settlement memory request)
        internal
        view
        returns (address payee, address providerOwner, address providerWallet)
    {
        require(registry.getProvider(request.providerAgentId).isActive, "provider not active");

        (uint256 providerAgentId, bool active, address owner, address wallet, address resolvedPayee) =
            serviceRegistry.resolveSettlement(request.serviceId);
        require(providerAgentId == request.providerAgentId, "service/provider mismatch");
        require(active, "service not active");
        providerOwner = owner;
        providerWallet = wallet;
        payee = resolvedPayee;
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
        _requireRefundParticipantsAllowed(record.providerAgentId, msg.sender, record.cachedBuyerWallet);
        _refundedAmount[paymentId] = cumulative;

        IERC20(record.token).safeTransferFrom(msg.sender, record.cachedBuyerWallet, amountToBuyer);
        emit Refunded(paymentId, amountToBuyer, cumulative);
        _attemptReputationSync(paymentId);
    }

    /// @inheritdoc IPaymentRouter
    function syncReputation(uint256 paymentId) external nonReentrant {
        require(_payments[paymentId].amount > 0, "payment not found");
        _syncPayment(paymentId);
        _syncRefund(paymentId);
    }

    function _isReputationEligible(
        Settlement memory request,
        uint256 commission,
        address buyerOwner,
        address buyerAgentWallet,
        address payee,
        address providerOwner,
        address providerWallet
    ) private view returns (bool) {
        TokenReputationConfig storage config = _tokenReputationConfigs[request.token];
        if (!config.enabled || request.amount < config.minimumAmount) return false;
        if (commission == 0) return false;
        if (request.buyerAgentId == request.providerAgentId) return false;
        address[3] memory buyerAddresses = [request.buyerWallet, buyerOwner, buyerAgentWallet];
        address[3] memory providerAddresses = [providerOwner, providerWallet, payee];
        return !LibReputationEligibility.hasProvableControlOverlap(
            identity, request.providerAgentId, buyerAddresses, providerAddresses
        );
    }

    function _attemptReputationSync(uint256 paymentId) private {
        if (!_reputationPaymentSynced[paymentId]) {
            try IReputationSink(reputationStorage).recordPayment(paymentId) {
                _reputationPaymentSynced[paymentId] = true;
                emit ReputationPaymentSynced(paymentId);
            } catch {
                emit ReputationSyncFailed(paymentId, IReputationSink.recordPayment.selector);
                return;
            }
        }

        uint256 unsyncedRefund = _refundedAmount[paymentId] - _reputationRefundSynced[paymentId];
        if (unsyncedRefund == 0) return;
        try IReputationSink(reputationStorage).recordRefund(paymentId, unsyncedRefund) {
            _reputationRefundSynced[paymentId] += unsyncedRefund;
            emit ReputationRefundSynced(paymentId, unsyncedRefund, _reputationRefundSynced[paymentId]);
        } catch {
            emit ReputationSyncFailed(paymentId, IReputationSink.recordRefund.selector);
        }
    }

    function _syncPayment(uint256 paymentId) private {
        if (_reputationPaymentSynced[paymentId]) return;
        IReputationSink(reputationStorage).recordPayment(paymentId);
        _reputationPaymentSynced[paymentId] = true;
        emit ReputationPaymentSynced(paymentId);
    }

    function _syncRefund(uint256 paymentId) private {
        uint256 unsyncedRefund = _refundedAmount[paymentId] - _reputationRefundSynced[paymentId];
        if (unsyncedRefund == 0) return;
        IReputationSink(reputationStorage).recordRefund(paymentId, unsyncedRefund);
        _reputationRefundSynced[paymentId] += unsyncedRefund;
        emit ReputationRefundSynced(paymentId, unsyncedRefund, _reputationRefundSynced[paymentId]);
    }
}
