// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEAS} from "../interfaces/IEAS.sol";
import {ReputationStorageBase} from "./ReputationStorageBase.sol";

/// @notice One-time resolver configuration for the reputation ledger.
abstract contract ReputationAdmin is ReputationStorageBase {
    function isConfigured() external view returns (bool) {
        return _configured;
    }

    function setEAS(address newEAS) external onlyAdmin {
        _requireMutableConfiguration();
        require(newEAS != address(0), "zero eas");
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

    function finalizeConfiguration() external onlyAdmin {
        _requireMutableConfiguration();
        require(address(paymentRouter).code.length > 0, "router has no code");
        require(address(eas).code.length > 0, "eas not configured");
        require(outcomeSchema != bytes32(0), "outcome schema not configured");
        require(confirmationSchema != bytes32(0), "confirmation schema not configured");
        require(outcomeSchema != confirmationSchema, "schemas must differ");
        _configured = true;
        emit ConfigurationFinalized(address(paymentRouter), address(eas), outcomeSchema, confirmationSchema);
    }

    function _requireMutableConfiguration() private view {
        require(!_configured, "configuration finalized");
        require(recordIds.length == 0, "records exist");
    }
}
