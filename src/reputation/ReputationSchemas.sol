// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Canonical EAS schema definitions used by reputation contracts and deployment tooling.
library ReputationSchemas {
    string internal constant OUTCOME_SCHEMA = "bytes32 orderKey,uint8 outcome";
    string internal constant CONFIRMATION_SCHEMA = "bytes32 orderKey,uint8 confirmation";
    string internal constant RECOVERY_SCHEMA = "bytes32 orderKey,bytes32 recoveryEvidenceHash";

    function outcomeSchema() internal pure returns (string memory) {
        return OUTCOME_SCHEMA;
    }

    function confirmationSchema() internal pure returns (string memory) {
        return CONFIRMATION_SCHEMA;
    }

    function recoverySchema() internal pure returns (string memory) {
        return RECOVERY_SCHEMA;
    }

    function outcomeSchemaHash() internal pure returns (bytes32) {
        return keccak256(bytes(OUTCOME_SCHEMA));
    }

    function confirmationSchemaHash() internal pure returns (bytes32) {
        return keccak256(bytes(CONFIRMATION_SCHEMA));
    }

    function recoverySchemaHash() internal pure returns (bytes32) {
        return keccak256(bytes(RECOVERY_SCHEMA));
    }
}
