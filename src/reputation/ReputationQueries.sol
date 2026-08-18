// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReputationAdmin} from "./ReputationAdmin.sol";

/// @notice Standard-order identity commitments and aggregate reputation views.
abstract contract ReputationQueries is ReputationAdmin {
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
}
