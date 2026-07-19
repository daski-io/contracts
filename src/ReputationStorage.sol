// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "./interfaces/IEAS.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {ISchemaResolver} from "./interfaces/ISchemaResolver.sol";
import {ReputationAccounting} from "./reputation/ReputationAccounting.sol";

/// @notice EAS-backed bilateral reputation aggregator. PaymentRouter creates
///         every record atomically at settlement, so missing provider outcomes
///         remain visible in provider/service transaction totals. Providers
///         attest outcomes and buyers submit revocable confirmations.
contract ReputationStorage is ReputationAccounting, ISchemaResolver {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address paymentRouter_, address admin_) external initializer {
        _initializeReputation(paymentRouter_, admin_);
    }

    function isPayable() external pure override returns (bool) {
        return false;
    }

    /// @notice Contract semver, per the canonical EAS resolver surface.
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    function attest(Attestation calldata attestation) external payable override onlyEAS returns (bool) {
        _handleAttest(attestation);
        return true;
    }

    function multiAttest(Attestation[] calldata attestations, uint256[] calldata)
        external
        payable
        override
        onlyEAS
        returns (bool)
    {
        for (uint256 i = 0; i < attestations.length; i++) {
            _handleAttest(attestations[i]);
        }
        return true;
    }

    function revoke(Attestation calldata attestation) external payable override onlyEAS returns (bool) {
        _handleRevoke(attestation);
        return true;
    }

    function multiRevoke(Attestation[] calldata attestations, uint256[] calldata)
        external
        payable
        override
        onlyEAS
        returns (bool)
    {
        for (uint256 i = 0; i < attestations.length; i++) {
            _handleRevoke(attestations[i]);
        }
        return true;
    }

    function _handleAttest(Attestation calldata a) internal {
        require(a.expirationTime == 0, "expiring attestations unsupported");
        require(a.revocationTime == 0, "attestation revoked");
        if (a.schema == outcomeSchema) {
            _onOutcomeAttest(a);
        } else if (a.schema == confirmationSchema) {
            _onConfirmationAttest(a);
        } else {
            revert("unknown schema");
        }
    }

    function _handleRevoke(Attestation calldata a) internal {
        if (a.schema == confirmationSchema) {
            _onConfirmationRevoke(a);
        } else if (a.schema == outcomeSchema) {
            revert("outcomes are not revocable");
        } else {
            revert("unknown schema");
        }
    }

    function _onOutcomeAttest(Attestation calldata a) internal {
        (uint256 paymentId, uint8 raw) = abi.decode(a.data, (uint256, uint8));
        require(raw <= uint8(TransactionOutcome.Canceled), "bad outcome");
        TransactionOutcome outcome = TransactionOutcome(raw);
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        require(_isHistoricalProvider(payment, a.attester), "not provider for this payment");
        require(a.recipient == _providerRecipient(payment), "wrong reputation recipient");

        ReputationRecord storage record = _records[paymentId];
        require(record.paymentId != 0, "payment not recorded");
        require(!record.outcomeRecorded, "outcome already recorded");

        uint256 attestationDelay = block.timestamp - payment.paidAt;
        record.outcome = outcome;
        record.outcomeAttestationDelay = attestationDelay;
        record.outcomeTimestamp = block.timestamp;
        record.outcomeRecorded = true;

        if (outcome == TransactionOutcome.Completed) {
            completedCount[payment.providerAgentId]++;
            completedByService[record.serviceId]++;
        } else if (outcome == TransactionOutcome.Failed) {
            failedCount[payment.providerAgentId]++;
            failedByService[record.serviceId]++;
        } else {
            canceledCount[payment.providerAgentId]++;
            canceledByService[record.serviceId]++;
        }

        emit OutcomeRecorded(
            paymentId, payment.providerAgentId, payment.buyerAgentId, record.serviceId, outcome, attestationDelay, a.uid
        );
    }

    function _onConfirmationAttest(Attestation calldata a) internal {
        (uint256 paymentId, uint8 raw) = abi.decode(a.data, (uint256, uint8));
        require(
            raw == uint8(BuyerConfirmation.Confirmed) || raw == uint8(BuyerConfirmation.NotConfirmed),
            "binary confirmation only"
        );

        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        require(a.attester == payment.cachedBuyerWallet, "not buyer for this payment");
        require(a.recipient == _providerRecipient(payment), "wrong reputation recipient");

        ReputationRecord storage record = _records[paymentId];
        require(record.paymentId != 0, "payment not recorded");
        BuyerConfirmation confirmation = BuyerConfirmation(raw);

        bytes32 currentUid = record.currentConfirmationUid;
        if (currentUid != bytes32(0)) {
            require(a.refUID == currentUid, "must ref current confirmation");
            require(a.refUID != a.uid, "self refUID");
        } else {
            require(a.refUID == bytes32(0), "refUID is not a tracked confirmation");
        }

        _transitionConfirmation(payment, record, confirmation, a.uid);

        emit BuyerConfirmationSubmitted(
            paymentId, payment.providerAgentId, payment.buyerAgentId, record.serviceId, confirmation, a.uid, a.refUID
        );
    }

    function _onConfirmationRevoke(Attestation calldata a) internal {
        uint256 paymentId = paymentIdByUid[a.uid];
        if (paymentId == 0) return;
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        ReputationRecord storage record = _records[paymentId];
        if (record.currentConfirmationUid != a.uid) return;
        _transitionConfirmation(payment, record, BuyerConfirmation.Pending, bytes32(0));
    }

    function _transitionConfirmation(
        IPaymentRouter.PaymentRecord memory payment,
        ReputationRecord storage record,
        BuyerConfirmation next,
        bytes32 nextUid
    ) private {
        bytes32 previousUid = record.currentConfirmationUid;
        if (previousUid != bytes32(0)) {
            BuyerConfirmation previous = confirmationByUid[previousUid];
            _decrementConfirmation(payment, record.serviceId, previous);
            delete confirmationByUid[previousUid];
            delete paymentIdByUid[previousUid];
        }

        record.confirmation = next;
        record.currentConfirmationUid = nextUid;
        record.confirmationTimestamp = nextUid == bytes32(0) ? 0 : block.timestamp;
        if (nextUid != bytes32(0)) {
            _incrementConfirmation(payment, record.serviceId, next);
            confirmationByUid[nextUid] = next;
            paymentIdByUid[nextUid] = record.paymentId;
        }
    }

    function _incrementConfirmation(
        IPaymentRouter.PaymentRecord memory payment,
        bytes32 serviceId,
        BuyerConfirmation confirmation
    ) private {
        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[payment.providerAgentId]++;
            confirmedByService[serviceId]++;
            buyerConfirmedCount[payment.buyerAgentId]++;
        } else {
            notConfirmedCount[payment.providerAgentId]++;
            notConfirmedByService[serviceId]++;
            buyerNotConfirmedCount[payment.buyerAgentId]++;
        }
    }

    function _decrementConfirmation(
        IPaymentRouter.PaymentRecord memory payment,
        bytes32 serviceId,
        BuyerConfirmation confirmation
    ) private {
        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[payment.providerAgentId]--;
            confirmedByService[serviceId]--;
            buyerConfirmedCount[payment.buyerAgentId]--;
        } else {
            notConfirmedCount[payment.providerAgentId]--;
            notConfirmedByService[serviceId]--;
            buyerNotConfirmedCount[payment.buyerAgentId]--;
        }
    }

    function _isHistoricalProvider(IPaymentRouter.PaymentRecord memory payment, address account)
        private
        pure
        returns (bool)
    {
        return account == payment.cachedProviderOwner || account == payment.cachedProviderWallet;
    }

    function _providerRecipient(IPaymentRouter.PaymentRecord memory payment) private pure returns (address) {
        if (payment.cachedProviderWallet != address(0)) return payment.cachedProviderWallet;
        return payment.cachedProviderOwner;
    }
}
