// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEAS, ISchemaRegistry, SchemaRecord} from "../interfaces/IEAS.sol";
import {ReputationSchemas} from "./ReputationSchemas.sol";
import {ReputationStorageBase} from "./ReputationStorageBase.sol";

/// @notice One-time EAS configuration, recovery controls, and explicit order-signer governance.
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

    /// @notice Binds the irrevocable recovery schema once, after configuration is
    ///         finalized. Also callable by the admin through `upgradeToAndCall`.
    function configureRecoverySchema(bytes32 schema) external onlyAdmin {
        if (!_configured) revert ConfigurationNotFinalized();
        if (recoverySchema != bytes32(0)) revert RecoverySchemaAlreadyConfigured();
        if (schema == bytes32(0)) revert ZeroSchema();
        if (schema == outcomeSchema || schema == confirmationSchema) revert SchemasMustDiffer();
        _requireSchema(eas.getSchemaRegistry(), schema, ReputationSchemas.recoverySchemaHash(), false);
        recoverySchema = schema;
        emit RecoverySchemaConfigured(schema);
    }

    /// @notice The admin may enable or disable recovery submissions; the pause
    ///         guardian may only disable them.
    function setRecoverySubmissionsEnabled(bool enabled) external {
        if (msg.sender != admin) {
            if (msg.sender != pauseGuardian) revert NotAdminOrPauseGuardian();
            if (enabled) revert RecoveryEnableRequiresAdmin();
        }
        recoverySubmissionsEnabled = enabled;
        emit RecoverySubmissionsEnabledUpdated(enabled, msg.sender);
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
