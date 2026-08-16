// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "./interfaces/IEAS.sol";
import {ISchemaResolver} from "./interfaces/ISchemaResolver.sol";
import {ReputationAccounting} from "./reputation/ReputationAccounting.sol";

/// @notice EAS-backed reputation ledger for finalized standard Exact-EVM orders.
contract ReputationStorage is ReputationAccounting, ISchemaResolver {
    uint8 public constant MAX_CONFIRMATION_TRANSITIONS = 3;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address orderSigner_,
        address identityRegistry_,
        address providerRegistry_,
        address serviceRegistry_,
        address sanctionsOracle_,
        address canonicalToken_,
        address admin_
    ) external initializer {
        _initializeReputation(
            orderSigner_,
            identityRegistry_,
            providerRegistry_,
            serviceRegistry_,
            sanctionsOracle_,
            canonicalToken_,
            admin_
        );
    }

    function isPayable() external pure override returns (bool) {
        return false;
    }

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }

    function attest(Attestation calldata attestation)
        external
        payable
        override
        onlyEAS
        whenExternalDependencyOperational
        returns (bool)
    {
        if (msg.value != 0) revert ValueUnsupported();
        _handleAttest(attestation);
        return true;
    }

    function multiAttest(Attestation[] calldata attestations, uint256[] calldata values)
        external
        payable
        override
        onlyEAS
        whenExternalDependencyOperational
        returns (bool)
    {
        if (!(msg.value == 0 && attestations.length == values.length)) revert InvalidBatchValues();
        for (uint256 i = 0; i < attestations.length; i++) {
            if (values[i] != 0) revert ValueUnsupported();
            _handleAttest(attestations[i]);
        }
        return true;
    }

    function revoke(Attestation calldata attestation)
        external
        payable
        override
        onlyEAS
        whenExternalDependencyOperational
        returns (bool)
    {
        if (msg.value != 0) revert ValueUnsupported();
        _handleRevoke(attestation);
        return true;
    }

    function multiRevoke(Attestation[] calldata attestations, uint256[] calldata values)
        external
        payable
        override
        onlyEAS
        whenExternalDependencyOperational
        returns (bool)
    {
        if (!(msg.value == 0 && attestations.length == values.length)) revert InvalidBatchValues();
        for (uint256 i = 0; i < attestations.length; i++) {
            if (values[i] != 0) revert ValueUnsupported();
            _handleRevoke(attestations[i]);
        }
        return true;
    }

    function _handleAttest(Attestation calldata a) private {
        if (!_configured) revert ConfigurationNotFinalized();
        if (!(a.expirationTime == 0 && a.revocationTime == 0)) revert InvalidAttestationTime();
        _requireNotSanctioned(a.attester);
        _requireNotSanctioned(a.recipient);
        if (a.schema == outcomeSchema) {
            _onOutcomeAttest(a);
        } else if (a.schema == confirmationSchema) {
            _onConfirmationAttest(a);
        } else {
            revert UnknownSchema();
        }
    }

    function _handleRevoke(Attestation calldata a) private {
        if (!_configured) revert ConfigurationNotFinalized();
        if (a.schema != confirmationSchema) revert OutcomeNotRevocable();
        if (!(a.expirationTime == 0 && a.revocationTime != 0 && a.revocable)) revert InvalidRevocation();
        _requireNotSanctioned(a.attester);
        _requireNotSanctioned(a.recipient);
        (bytes32 encodedOrderKey,) = abi.decode(a.data, (bytes32, uint8));
        bytes32 orderKey = orderKeyByConfirmationUid[a.uid];
        if (!(orderKey != bytes32(0) && orderKey == encodedOrderKey)) revert UnknownConfirmation();
        ReputationRecord storage record = _records[orderKey];
        if (record.currentConfirmationUid != a.uid) revert StaleConfirmation();
        if (a.attester != record.payer) revert NotOrderPayer();
        if (a.recipient != _providerRecipient(record)) revert WrongReputationRecipient();
        _transitionConfirmation(record, BuyerConfirmation.Pending, bytes32(0));
        emit BuyerConfirmationRevoked(
            orderKey, a.uid, record.providerAgentId, record.serviceId, record.payer, record.confirmationTransitions
        );
    }

    function _onOutcomeAttest(Attestation calldata a) private {
        if (!(!a.revocable && a.refUID == bytes32(0))) revert InvalidOutcomeSemantics();
        (bytes32 orderKey, uint8 raw) = abi.decode(a.data, (bytes32, uint8));
        if (raw > uint8(TransactionOutcome.Canceled)) revert BadOutcome();
        ReputationRecord storage record = _eligibleRecord(orderKey);
        if (record.outcomeRecorded) revert OutcomeAlreadyRecorded();
        if (!(a.attester == record.providerOwner || a.attester == record.providerAgentWallet)) {
            revert NotOrderProvider();
        }
        if (a.recipient != _providerRecipient(record)) revert WrongReputationRecipient();
        if (!(a.time >= record.paidAt && a.time <= block.timestamp)) revert InvalidAttestationTimestamp();

        TransactionOutcome outcome = TransactionOutcome(raw);
        uint64 delay = a.time - record.paidAt;
        record.outcome = outcome;
        record.outcomeAttestationDelay = delay;
        record.outcomeTimestamp = a.time;
        record.outcomeRecorded = true;
        outcomeDelayTotalByProvider[record.providerAgentId] += delay;
        if (outcome == TransactionOutcome.Completed) {
            completedCount[record.providerAgentId]++;
            completedByService[record.serviceId]++;
        } else if (outcome == TransactionOutcome.Failed) {
            failedCount[record.providerAgentId]++;
            failedByService[record.serviceId]++;
        } else {
            canceledCount[record.providerAgentId]++;
            canceledByService[record.serviceId]++;
        }
        emit OutcomeRecorded(orderKey, record.providerAgentId, record.payer, record.serviceId, outcome, delay, a.uid);
    }

    function _onConfirmationAttest(Attestation calldata a) private {
        if (!a.revocable) revert ConfirmationMustBeRevocable();
        (bytes32 orderKey, uint8 raw) = abi.decode(a.data, (bytes32, uint8));
        if (!(raw == uint8(BuyerConfirmation.Confirmed) || raw == uint8(BuyerConfirmation.NotConfirmed))) {
            revert BinaryConfirmationOnly();
        }
        ReputationRecord storage record = _eligibleRecord(orderKey);
        if (a.attester != record.payer) revert NotOrderPayer();
        if (a.recipient != _providerRecipient(record)) revert WrongReputationRecipient();
        bytes32 currentUid = record.currentConfirmationUid;
        if (currentUid == bytes32(0)) {
            if (a.refUID != bytes32(0)) revert UnexpectedConfirmationReference();
        } else {
            if (!(a.refUID == currentUid && a.refUID != a.uid)) revert MustReferenceCurrentConfirmation();
        }
        BuyerConfirmation confirmation = BuyerConfirmation(raw);
        _transitionConfirmation(record, confirmation, a.uid);
        emit BuyerConfirmationSubmitted(
            orderKey,
            record.providerAgentId,
            record.payer,
            record.serviceId,
            confirmation,
            a.uid,
            a.refUID,
            record.confirmationTransitions
        );
    }

    function _transitionConfirmation(ReputationRecord storage record, BuyerConfirmation next, bytes32 nextUid) private {
        if (record.confirmationTransitions >= MAX_CONFIRMATION_TRANSITIONS) revert ConfirmationTransitionCap();
        bytes32 previousUid = record.currentConfirmationUid;
        if (previousUid != bytes32(0)) {
            _decrementConfirmation(record, confirmationByUid[previousUid]);
            delete confirmationByUid[previousUid];
            delete orderKeyByConfirmationUid[previousUid];
        }
        record.confirmationTransitions++;
        record.confirmation = next;
        record.currentConfirmationUid = nextUid;
        record.confirmationTimestamp = nextUid == bytes32(0) ? 0 : uint64(block.timestamp);
        if (nextUid != bytes32(0)) {
            _incrementConfirmation(record, next);
            confirmationByUid[nextUid] = next;
            orderKeyByConfirmationUid[nextUid] = record.orderKey;
        }
    }

    function _incrementConfirmation(ReputationRecord storage record, BuyerConfirmation confirmation) private {
        uint256 weight = _valueWeight(record.grossAmount);
        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[record.providerAgentId]++;
            confirmedByService[record.serviceId]++;
            payerConfirmedCount[record.payer]++;
            confirmedWeightByProvider[record.providerAgentId] += weight;
            confirmedWeightByService[record.serviceId] += weight;
        } else {
            notConfirmedCount[record.providerAgentId]++;
            notConfirmedByService[record.serviceId]++;
            payerNotConfirmedCount[record.payer]++;
            notConfirmedWeightByProvider[record.providerAgentId] += weight;
            notConfirmedWeightByService[record.serviceId] += weight;
        }
    }

    function _decrementConfirmation(ReputationRecord storage record, BuyerConfirmation confirmation) private {
        uint256 weight = _valueWeight(record.grossAmount);
        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[record.providerAgentId]--;
            confirmedByService[record.serviceId]--;
            payerConfirmedCount[record.payer]--;
            confirmedWeightByProvider[record.providerAgentId] -= weight;
            confirmedWeightByService[record.serviceId] -= weight;
        } else {
            notConfirmedCount[record.providerAgentId]--;
            notConfirmedByService[record.serviceId]--;
            payerNotConfirmedCount[record.payer]--;
            notConfirmedWeightByProvider[record.providerAgentId] -= weight;
            notConfirmedWeightByService[record.serviceId] -= weight;
        }
    }

    function _eligibleRecord(bytes32 orderKey) private view returns (ReputationRecord storage record) {
        record = _records[orderKey];
        if (record.orderKey == bytes32(0)) revert OrderNotRecorded();
        if (!record.reputationEligible) revert OrderNotReputationEligible();
    }

    function _providerRecipient(ReputationRecord storage record) private view returns (address) {
        return record.providerAgentWallet == address(0) ? record.providerOwner : record.providerAgentWallet;
    }
}
