// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEAS, ISchemaRegistry, SchemaRecord} from "../interfaces/IEAS.sol";
import {ReputationSchemas} from "./ReputationSchemas.sol";
import {ReputationStorageBase} from "./ReputationStorageBase.sol";

/// @notice One-time EAS configuration and explicit order-signer governance.
abstract contract ReputationAdmin is ReputationStorageBase {
    function isConfigured() external view returns (bool) {
        return _configured;
    }

    function expectedOutcomeSchemaHash() external pure returns (bytes32) {
        return ReputationSchemas.outcomeSchemaHash();
    }

    function expectedConfirmationSchemaHash() external pure returns (bytes32) {
        return ReputationSchemas.confirmationSchemaHash();
    }

    function setEAS(address newEAS) external onlyAdmin {
        _requireMutableConfiguration();
        require(newEAS.code.length > 0, "eas has no code");
        address oldEAS = address(eas);
        eas = IEAS(newEAS);
        emit EASUpdated(oldEAS, newEAS);
    }

    function setOutcomeSchema(bytes32 newSchema) external onlyAdmin {
        _requireMutableConfiguration();
        require(newSchema != bytes32(0), "zero schema");
        require(newSchema != confirmationSchema, "schemas must differ");
        bytes32 oldSchema = outcomeSchema;
        outcomeSchema = newSchema;
        emit OutcomeSchemaUpdated(oldSchema, newSchema);
    }

    function setConfirmationSchema(bytes32 newSchema) external onlyAdmin {
        _requireMutableConfiguration();
        require(newSchema != bytes32(0), "zero schema");
        require(newSchema != outcomeSchema, "schemas must differ");
        bytes32 oldSchema = confirmationSchema;
        confirmationSchema = newSchema;
        emit ConfirmationSchemaUpdated(oldSchema, newSchema);
    }

    function setOrderSigner(address newSigner) external onlyAdmin {
        require(newSigner != address(0) && newSigner != admin && newSigner != pendingAdmin, "invalid order signer");
        address oldSigner = orderSigner;
        orderSigner = newSigner;
        emit OrderSignerUpdated(oldSigner, newSigner);
    }

    function finalizeConfiguration() external onlyAdmin {
        _requireMutableConfiguration();
        require(address(eas).code.length > 0, "eas not configured");
        require(orderSigner != address(0) && orderSigner != admin, "invalid order signer");
        require(outcomeSchema != bytes32(0), "outcome schema not configured");
        require(confirmationSchema != bytes32(0), "confirmation schema not configured");
        require(outcomeSchema != confirmationSchema, "schemas must differ");
        ISchemaRegistry registry = eas.getSchemaRegistry();
        require(address(registry).code.length > 0, "schema registry has no code");
        _requireSchema(registry, outcomeSchema, ReputationSchemas.outcomeSchemaHash(), false, "outcome");
        _requireSchema(registry, confirmationSchema, ReputationSchemas.confirmationSchemaHash(), true, "confirmation");
        _configured = true;
        emit ConfigurationFinalized(
            address(eas),
            orderSigner,
            identityRegistry,
            address(providerRegistry),
            address(serviceRegistry),
            outcomeSchema,
            confirmationSchema
        );
    }

    function _requireSchema(
        ISchemaRegistry registry,
        bytes32 uid,
        bytes32 expectedHash,
        bool expectedRevocable,
        string memory kind
    ) private view {
        SchemaRecord memory schema = registry.getSchema(uid);
        require(schema.uid == uid, string.concat(kind, " schema missing"));
        require(schema.resolver == address(this), string.concat("wrong ", kind, " resolver"));
        require(keccak256(bytes(schema.schema)) == expectedHash, string.concat("wrong ", kind, " schema"));
        if (expectedRevocable) {
            require(schema.revocable, string.concat(kind, " schema not revocable"));
        } else {
            require(!schema.revocable, string.concat(kind, " schema revocable"));
        }
    }

    function _requireMutableConfiguration() private view {
        require(!_configured, "configuration finalized");
        require(recordKeys.length == 0, "records exist");
    }
}
