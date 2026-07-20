// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploymentValidation} from "../../script/DeploymentValidation.sol";

contract DeploymentValidationHarness {
    function validateExternalDependencies(
        address identity,
        address usdc,
        address eas,
        address schemaRegistry,
        bool allowUnsupportedChain
    ) external view {
        DeploymentValidation.validateExternalDependencies(identity, usdc, eas, schemaRegistry, allowUnsupportedChain);
    }

    function validateFinalAdmin(address finalAdmin, address deployer) external view {
        DeploymentValidation.validateFinalAdmin(finalAdmin, deployer);
    }

    function validateCoreWiring(DeploymentValidation.Stack calldata deployment) external view {
        DeploymentValidation.validateCoreWiring(deployment);
    }

    function validateDarkState(DeploymentValidation.Stack calldata deployment) external view {
        DeploymentValidation.validateDarkState(deployment);
    }

    function validateOperationalState(DeploymentValidation.Stack calldata deployment) external view {
        DeploymentValidation.validateOperationalState(deployment);
    }

    function validateAcceptedAdmins(address[9] calldata contracts_, address expectedAdmin) external view {
        DeploymentValidation.validateAcceptedAdmins(contracts_, expectedAdmin);
    }
}
