// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {IExternalDependencyGuard} from "../src/interfaces/IExternalDependencyGuard.sol";

interface IPaymentRouterGovernance {
    function setAcceptedToken(address token, bool allowed) external;
    function setTokenReputationConfig(address token, bool enabled, uint256 minimumAmount) external;
    function setAdapter(address adapter, bool allowed) external;
}

/// @notice Deterministic calls for the two Safe batches in a staged deployment.
library GovernanceBatches {
    function adminAcceptance(DeploymentValidation.Stack memory deployment)
        internal
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        address[9] memory contracts_ = DeploymentValidation.adminContracts(deployment);
        targets = new address[](contracts_.length);
        calls = new bytes[](contracts_.length);
        for (uint256 i = 0; i < contracts_.length; i++) {
            targets[i] = contracts_[i];
            calls[i] = abi.encodeCall(Admin2StepUpgradeable.acceptAdmin, ());
        }
    }

    function paymentActivation(DeploymentValidation.Stack memory deployment)
        internal
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        targets = new address[](5);
        calls = new bytes[](5);
        for (uint256 i = 0; i < targets.length; i++) {
            targets[i] = deployment.router;
        }

        calls[0] = abi.encodeCall(IPaymentRouterGovernance.setAcceptedToken, (deployment.usdc, true));
        calls[1] = abi.encodeCall(
            IPaymentRouterGovernance.setTokenReputationConfig, (deployment.usdc, true, deployment.reputationMinimum)
        );
        calls[2] = abi.encodeCall(IPaymentRouterGovernance.setAdapter, (deployment.x402Adapter, true));
        calls[3] = abi.encodeCall(IPaymentRouterGovernance.setAdapter, (deployment.permitAdapter, true));
        calls[4] = abi.encodeCall(IPaymentRouterGovernance.setAdapter, (deployment.approvalAdapter, true));
    }

    function externalDependencyPause(DeploymentValidation.Stack memory deployment)
        internal
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        return _externalDependencyState(deployment, true);
    }

    function pauseGuardianConfiguration(DeploymentValidation.Stack memory deployment, address guardian)
        internal
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        require(guardian != address(0), "zero pause guardian");
        address[9] memory contracts_ = DeploymentValidation.adminContracts(deployment);
        targets = new address[](contracts_.length);
        calls = new bytes[](contracts_.length);
        for (uint256 i = 0; i < contracts_.length; i++) {
            targets[i] = contracts_[i];
            calls[i] = abi.encodeCall(IExternalDependencyGuard.setPauseGuardian, (guardian));
        }
    }

    function externalDependencyUnpause(DeploymentValidation.Stack memory deployment)
        internal
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        return _externalDependencyState(deployment, false);
    }

    function _externalDependencyState(DeploymentValidation.Stack memory deployment, bool paused)
        private
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        address[9] memory contracts_ = DeploymentValidation.adminContracts(deployment);
        targets = new address[](contracts_.length);
        calls = new bytes[](contracts_.length);
        for (uint256 i = 0; i < contracts_.length; i++) {
            targets[i] = contracts_[i];
            calls[i] = paused
                ? abi.encodeCall(IExternalDependencyGuard.pauseExternalDependency, ())
                : abi.encodeCall(IExternalDependencyGuard.unpauseExternalDependency, ());
        }
    }
}
