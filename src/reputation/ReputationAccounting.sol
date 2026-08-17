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
        if (!_configured) revert ConfigurationNotFinalized();
        if (block.timestamp > permit.validBefore) revert OrderPermitExpired();
        if (!SignatureChecker.isValidSignatureNow(orderSigner, orderDigest(permit), signature)) {
            revert InvalidOrderSignature();
        }
        _validateOrder(permit);
        if (_records[permit.orderKey].orderKey != bytes32(0)) revert OrderAlreadyRecorded();
        if (authorizationKeyUsed[permit.authorizationKey]) revert AuthorizationAlreadyRecorded();

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
            confirmationSubmissions: 0,
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
        if (!_configured) revert ConfigurationNotFinalized();
        if (block.timestamp > permit.validBefore) revert RefundPermitExpired();
        if (!SignatureChecker.isValidSignatureNow(orderSigner, refundDigest(permit), signature)) {
            revert InvalidRefundSignature();
        }
        if (permit.refundEvidenceHash == bytes32(0)) revert ZeroRefundEvidence();
        ReputationRecord storage record = _records[permit.orderKey];
        if (record.orderKey == bytes32(0)) revert OrderNotRecorded();
        if (record.authorizationKey != permit.authorizationKey) revert AuthorizationMismatch();
        uint256 previous = refundedAmount[permit.orderKey];
        if (permit.cumulativeRefundedAmount <= previous) revert RefundNotMonotonic();
        if (permit.cumulativeRefundedAmount > record.grossAmount) revert RefundExceedsGross();
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
        if (!(permit.orderKey != bytes32(0) && permit.authorizationKey != bytes32(0))) revert ZeroOrderIdentifier();
        if (!(permit.providerAgentId != 0 && permit.serviceId != bytes32(0))) revert ZeroProviderOrService();
        if (!(permit.payer != address(0) && permit.providerOwner != address(0)
                    && permit.providerAgentWallet != address(0))) revert ZeroParticipant();
        if (!(permit.providerPayee != address(0) && permit.canonicalToken == canonicalToken)) {
            revert PaymentTokenMismatch();
        }
        if (!(permit.grossAmount != 0 && permit.paidAt != 0 && permit.paidAt <= block.timestamp)) {
            revert InvalidPaymentFacts();
        }
        if (!(permit.blockNumber != 0 && permit.blockNumber <= block.number)) revert InvalidSnapshotBlock();
        if (permit.blockHash == bytes32(0)) revert ZeroSnapshotBlockHash();
        if (!(permit.listingManifestHash != bytes32(0) && permit.releaseEvidenceHash != bytes32(0))) {
            revert ZeroEvidenceHash();
        }
        if (permit.identityRegistry != identityRegistry) revert IdentityRegistryMismatch();
        if (permit.providerRegistry != address(providerRegistry)) revert ProviderRegistryMismatch();
        if (permit.serviceRegistry != address(serviceRegistry)) revert ServiceRegistryMismatch();
        if (!providerRegistry.isRegistered(permit.providerAgentId)) revert ProviderNotRegistered();
        IServiceRegistry.Service memory service = serviceRegistry.getService(permit.serviceId);
        if (!(service.providerAgentId == permit.providerAgentId && service.serviceId == permit.serviceId)) {
            revert ServiceMismatch();
        }
        if (providerIdentitySnapshotHash(permit) != permit.providerIdentitySnapshotHash) revert SnapshotHashMismatch();
        if (!(permit.payer != permit.providerOwner && permit.payer != permit.providerAgentWallet
                    && permit.payer != permit.providerPayee)) revert ProviderSelfPurchase();
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
