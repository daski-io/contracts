// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IServiceRegistry} from "../interfaces/IServiceRegistry.sol";
import {ReputationAdmin} from "./ReputationAdmin.sol";

/// @notice Signed standard-order registration, refund accounting, and views.
abstract contract ReputationAccounting is ReputationAdmin {
    uint256 internal constant VALUE_WEIGHT_FLOOR = 250_000;

    function registerOrder(StandardReputationOrderV1 calldata permit, bytes calldata signature)
        external
        whenExternalDependencyOperational
    {
        require(_configured, "configuration not finalized");
        require(block.timestamp <= permit.validBefore, "order permit expired");
        require(
            SignatureChecker.isValidSignatureNow(orderSigner, orderDigest(permit), signature), "invalid order signature"
        );
        _validateOrder(permit);
        require(_records[permit.orderKey].orderKey == bytes32(0), "order already recorded");
        require(!authorizationKeyUsed[permit.authorizationKey], "authorization already recorded");

        _records[permit.orderKey] = ReputationRecord({
            orderKey: permit.orderKey,
            authorizationKey: permit.authorizationKey,
            providerAgentId: permit.providerAgentId,
            serviceId: permit.serviceId,
            payer: permit.payer,
            providerOwner: permit.providerOwner,
            providerAgentWallet: permit.providerAgentWallet,
            providerPayee: permit.providerPayee,
            canonicalToken: permit.canonicalToken,
            grossAmount: permit.grossAmount,
            paidAt: permit.paidAt,
            providerIdentitySnapshotHash: permit.providerIdentitySnapshotHash,
            listingManifestHash: permit.listingManifestHash,
            releaseEvidenceHash: permit.releaseEvidenceHash,
            outcome: TransactionOutcome.Completed,
            confirmation: BuyerConfirmation.Pending,
            outcomeAttestationDelay: 0,
            outcomeTimestamp: 0,
            confirmationTimestamp: 0,
            confirmationTransitions: 0,
            outcomeRecorded: false,
            reputationEligible: permit.reputationEligible,
            currentConfirmationUid: bytes32(0)
        });
        authorizationKeyUsed[permit.authorizationKey] = true;
        recordKeys.push(permit.orderKey);
        if (permit.reputationEligible) _incrementOrderCounters(permit);

        emit StandardOrderRegistered(
            permit.orderKey,
            permit.authorizationKey,
            permit.providerAgentId,
            permit.serviceId,
            permit.payer,
            permit.grossAmount,
            permit.reputationEligible
        );
    }

    function recordRefund(StandardReputationRefundV1 calldata permit, bytes calldata signature)
        external
        whenExternalDependencyOperational
    {
        require(_configured, "configuration not finalized");
        require(block.timestamp <= permit.validBefore, "refund permit expired");
        require(
            SignatureChecker.isValidSignatureNow(orderSigner, refundDigest(permit), signature),
            "invalid refund signature"
        );
        require(permit.refundEvidenceHash != bytes32(0), "zero refund evidence");
        ReputationRecord storage record = _records[permit.orderKey];
        require(record.orderKey != bytes32(0), "order not recorded");
        require(record.authorizationKey == permit.authorizationKey, "authorization mismatch");
        uint256 previous = refundedAmount[permit.orderKey];
        require(permit.cumulativeRefundedAmount > previous, "refund not monotonic");
        require(permit.cumulativeRefundedAmount <= record.grossAmount, "refund exceeds gross");
        uint256 delta = permit.cumulativeRefundedAmount - previous;
        refundedAmount[permit.orderKey] = permit.cumulativeRefundedAmount;
        if (record.reputationEligible) {
            refundedAmountByProvider[record.providerAgentId] += delta;
            refundedAmountByService[record.serviceId] += delta;
            refundedAmountByPayer[record.payer] += delta;
        }
        emit ReputationRefunded(
            permit.orderKey, record.serviceId, delta, permit.cumulativeRefundedAmount, permit.refundEvidenceHash
        );
    }

    function orderDigest(StandardReputationOrderV1 calldata permit) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(_encodeOrder(permit)));
    }

    function refundDigest(StandardReputationRefundV1 calldata permit) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REFUND_TYPEHASH,
                    permit.orderKey,
                    permit.authorizationKey,
                    permit.cumulativeRefundedAmount,
                    permit.refundEvidenceHash,
                    permit.validBefore
                )
            )
        );
    }

    function providerIdentitySnapshotHash(StandardReputationOrderV1 calldata permit) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                PROVIDER_IDENTITY_SNAPSHOT_V1_TYPEHASH,
                block.chainid,
                permit.providerAgentId,
                permit.serviceId,
                permit.identityRegistry,
                permit.providerRegistry,
                permit.serviceRegistry,
                permit.providerOwner,
                permit.providerAgentWallet,
                permit.providerPayee,
                permit.blockNumber,
                permit.blockHash
            )
        );
    }

    function getRecord(bytes32 orderKey) external view returns (ReputationRecord memory) {
        return _records[orderKey];
    }

    function getRecordCount() external view returns (uint256) {
        return recordKeys.length;
    }

    function getProviderStats(uint256 id) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            completedCount[id],
            failedCount[id],
            canceledCount[id],
            confirmedCount[id],
            notConfirmedCount[id],
            providerTransactionCount[id]
        );
    }

    function getServiceStats(bytes32 id)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (
            completedByService[id],
            failedByService[id],
            canceledByService[id],
            confirmedByService[id],
            notConfirmedByService[id],
            refundedAmountByService[id],
            serviceTransactionCount[id]
        );
    }

    function getBuyerStats(address payer) external view returns (uint256, uint256, uint256) {
        return (payerTransactionCount[payer], payerConfirmedCount[payer], payerNotConfirmedCount[payer]);
    }

    function _validateOrder(StandardReputationOrderV1 calldata permit) private view {
        require(permit.orderKey != bytes32(0) && permit.authorizationKey != bytes32(0), "zero order identifier");
        require(permit.providerAgentId != 0 && permit.serviceId != bytes32(0), "zero provider or service");
        require(
            permit.payer != address(0) && permit.providerOwner != address(0)
                && permit.providerAgentWallet != address(0),
            "zero participant"
        );
        require(permit.providerPayee != address(0) && permit.canonicalToken == canonicalToken, "payment token mismatch");
        require(
            permit.grossAmount != 0 && permit.paidAt != 0 && permit.paidAt <= block.timestamp, "invalid payment facts"
        );
        require(permit.blockNumber != 0 && permit.blockNumber <= block.number, "invalid snapshot block");
        require(permit.blockHash != bytes32(0), "zero snapshot block hash");
        require(
            permit.listingManifestHash != bytes32(0) && permit.releaseEvidenceHash != bytes32(0), "zero evidence hash"
        );
        require(permit.identityRegistry == identityRegistry, "identity registry mismatch");
        require(permit.providerRegistry == address(providerRegistry), "provider registry mismatch");
        require(permit.serviceRegistry == address(serviceRegistry), "service registry mismatch");
        require(providerRegistry.isRegistered(permit.providerAgentId), "provider not registered");
        IServiceRegistry.Service memory service = serviceRegistry.getService(permit.serviceId);
        require(
            service.providerAgentId == permit.providerAgentId && service.serviceId == permit.serviceId,
            "service mismatch"
        );
        require(providerIdentitySnapshotHash(permit) == permit.providerIdentitySnapshotHash, "snapshot hash mismatch");
        require(
            permit.payer != permit.providerOwner && permit.payer != permit.providerAgentWallet
                && permit.payer != permit.providerPayee,
            "provider self purchase"
        );
        _requireNotSanctioned(permit.payer);
        _requireNotSanctioned(permit.providerOwner);
        _requireNotSanctioned(permit.providerAgentWallet);
        _requireNotSanctioned(permit.providerPayee);
    }

    function _incrementOrderCounters(StandardReputationOrderV1 calldata permit) private {
        providerTransactionCount[permit.providerAgentId]++;
        serviceTransactionCount[permit.serviceId]++;
        payerTransactionCount[permit.payer]++;
        totalPaidByProvider[permit.providerAgentId] += permit.grossAmount;
        totalPaidByService[permit.serviceId] += permit.grossAmount;
        totalPaidByPayer[permit.payer] += permit.grossAmount;
    }

    function _valueWeight(uint256 amount) internal pure returns (uint256 weight) {
        uint256 scaled = amount < VALUE_WEIGHT_FLOOR ? VALUE_WEIGHT_FLOOR : amount;
        weight = 1;
        while (scaled >= VALUE_WEIGHT_FLOOR * 2) {
            scaled /= 2;
            weight++;
        }
    }

    function _encodeOrder(StandardReputationOrderV1 calldata p) private pure returns (bytes memory) {
        // A single 22-argument abi.encode cannot allocate its frame under
        // --ir-minimum (the coverage build). Every argument is a static type,
        // so two concatenated halves encode byte-identically.
        return bytes.concat(
            abi.encode(
                ORDER_TYPEHASH,
                p.orderKey,
                p.authorizationKey,
                p.providerAgentId,
                p.serviceId,
                p.payer,
                p.providerOwner,
                p.providerAgentWallet,
                p.providerPayee,
                p.identityRegistry,
                p.providerRegistry
            ),
            abi.encode(
                p.serviceRegistry,
                p.blockNumber,
                p.blockHash,
                p.canonicalToken,
                p.grossAmount,
                p.paidAt,
                p.providerIdentitySnapshotHash,
                p.listingManifestHash,
                p.releaseEvidenceHash,
                p.reputationEligible,
                p.validBefore
            )
        );
    }
}
