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
        require(msg.value == 0, "value unsupported");
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
        require(msg.value == 0 && attestations.length == values.length, "invalid batch values");
        for (uint256 i = 0; i < attestations.length; i++) {
            require(values[i] == 0, "value unsupported");
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
        require(msg.value == 0, "value unsupported");
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
        require(msg.value == 0 && attestations.length == values.length, "invalid batch values");
        for (uint256 i = 0; i < attestations.length; i++) {
            require(values[i] == 0, "value unsupported");
            _handleRevoke(attestations[i]);
        }
        return true;
    }

    function _handleAttest(Attestation calldata a) private {
        require(_configured, "configuration not finalized");
        require(a.expirationTime == 0 && a.revocationTime == 0, "invalid attestation time");
        _requireNotSanctioned(a.attester);
        _requireNotSanctioned(a.recipient);
        if (a.schema == outcomeSchema) {
            _onOutcomeAttest(a);
        } else if (a.schema == confirmationSchema) {
            _onConfirmationAttest(a);
        } else {
            revert("unknown schema");
        }
    }

    function _handleRevoke(Attestation calldata a) private {
        require(_configured, "configuration not finalized");
        require(a.schema == confirmationSchema, "outcomes are not revocable");
        require(a.expirationTime == 0 && a.revocationTime != 0 && a.revocable, "invalid revocation");
        _requireNotSanctioned(a.attester);
        _requireNotSanctioned(a.recipient);
        (bytes32 encodedOrderKey,) = abi.decode(a.data, (bytes32, uint8));
        bytes32 orderKey = orderKeyByConfirmationUid[a.uid];
        require(orderKey != bytes32(0) && orderKey == encodedOrderKey, "unknown confirmation");
        ReputationRecord storage record = _records[orderKey];
        require(record.currentConfirmationUid == a.uid, "stale confirmation");
        require(a.attester == record.payer, "not order payer");
        require(a.recipient == _providerRecipient(record), "wrong reputation recipient");
        _transitionConfirmation(record, BuyerConfirmation.Pending, bytes32(0));
        emit BuyerConfirmationRevoked(
            orderKey, a.uid, record.providerAgentId, record.serviceId, record.payer, record.confirmationTransitions
        );
    }

    function _onOutcomeAttest(Attestation calldata a) private {
        require(!a.revocable && a.refUID == bytes32(0), "invalid outcome semantics");
        (bytes32 orderKey, uint8 raw) = abi.decode(a.data, (bytes32, uint8));
        require(raw <= uint8(TransactionOutcome.Canceled), "bad outcome");
        ReputationRecord storage record = _eligibleRecord(orderKey);
        require(!record.outcomeRecorded, "outcome already recorded");
        require(a.attester == record.providerOwner || a.attester == record.providerAgentWallet, "not order provider");
        require(a.recipient == _providerRecipient(record), "wrong reputation recipient");
        require(a.time >= record.paidAt && a.time <= block.timestamp, "invalid attestation timestamp");

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
        require(a.revocable, "confirmation must be revocable");
        (bytes32 orderKey, uint8 raw) = abi.decode(a.data, (bytes32, uint8));
        require(
            raw == uint8(BuyerConfirmation.Confirmed) || raw == uint8(BuyerConfirmation.NotConfirmed),
            "binary confirmation only"
        );
        ReputationRecord storage record = _eligibleRecord(orderKey);
        require(a.attester == record.payer, "not order payer");
        require(a.recipient == _providerRecipient(record), "wrong reputation recipient");
        bytes32 currentUid = record.currentConfirmationUid;
        if (currentUid == bytes32(0)) {
            require(a.refUID == bytes32(0), "unexpected confirmation reference");
        } else {
            require(a.refUID == currentUid && a.refUID != a.uid, "must ref current confirmation");
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
        require(record.confirmationTransitions < MAX_CONFIRMATION_TRANSITIONS, "confirmation transition cap");
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
        require(record.orderKey != bytes32(0), "order not recorded");
        require(record.reputationEligible, "order not reputation eligible");
    }

    function _providerRecipient(ReputationRecord storage record) private view returns (address) {
        return record.providerAgentWallet == address(0) ? record.providerOwner : record.providerAgentWallet;
    }
}
