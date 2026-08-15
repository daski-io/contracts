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
        if (newEAS.code.length == 0) revert TargetHasNoCode(newEAS);
        address oldEAS = address(eas);
        eas = IEAS(newEAS);
        emit EASUpdated(oldEAS, newEAS);
    }

    function setOutcomeSchema(bytes32 newSchema) external onlyAdmin {
        _requireMutableConfiguration();
        if (newSchema == bytes32(0)) revert ZeroSchema();
        if (newSchema == confirmationSchema) revert SchemasMustDiffer();
        bytes32 oldSchema = outcomeSchema;
        outcomeSchema = newSchema;
        emit OutcomeSchemaUpdated(oldSchema, newSchema);
    }

    function setConfirmationSchema(bytes32 newSchema) external onlyAdmin {
        _requireMutableConfiguration();
        if (newSchema == bytes32(0)) revert ZeroSchema();
        if (newSchema == outcomeSchema) revert SchemasMustDiffer();
        bytes32 oldSchema = confirmationSchema;
        confirmationSchema = newSchema;
        emit ConfirmationSchemaUpdated(oldSchema, newSchema);
    }

    function setOrderSigner(address newSigner) external onlyAdmin {
        if (!(newSigner != address(0) && newSigner != admin && newSigner != pendingAdmin)) revert InvalidOrderSigner();
        address oldSigner = orderSigner;
        orderSigner = newSigner;
        emit OrderSignerUpdated(oldSigner, newSigner);
    }

    function finalizeConfiguration() external onlyAdmin {
        _requireMutableConfiguration();
        if (address(eas).code.length == 0) revert TargetHasNoCode(address(eas));
        if (!(orderSigner != address(0) && orderSigner != admin)) revert InvalidOrderSigner();
        if (outcomeSchema == bytes32(0)) revert OutcomeSchemaNotConfigured();
        if (confirmationSchema == bytes32(0)) revert ConfirmationSchemaNotConfigured();
        if (outcomeSchema == confirmationSchema) revert SchemasMustDiffer();
        ISchemaRegistry registry = eas.getSchemaRegistry();
        if (address(registry).code.length == 0) revert TargetHasNoCode(address(registry));
        _requireSchema(registry, outcomeSchema, ReputationSchemas.outcomeSchemaHash(), false);
        _requireSchema(registry, confirmationSchema, ReputationSchemas.confirmationSchemaHash(), true);
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

    function _requireSchema(ISchemaRegistry registry, bytes32 uid, bytes32 expectedHash, bool expectedRevocable)
        private
        view
    {
        SchemaRecord memory schema = registry.getSchema(uid);
        if (schema.uid != uid) revert SchemaMissing(uid);
        if (schema.resolver != address(this)) revert WrongSchemaResolver(uid);
        if (keccak256(bytes(schema.schema)) != expectedHash) revert WrongSchemaDefinition(uid);
        if (expectedRevocable) {
            if (!schema.revocable) revert SchemaMustBeRevocable(uid);
        } else {
            if (schema.revocable) revert SchemaMustBeIrrevocable(uid);
        }
    }

    function _requireMutableConfiguration() private view {
        if (_configured) revert ConfigurationIsFinalized();
        if (recordKeys.length != 0) revert RecordsExist();
    }
}
