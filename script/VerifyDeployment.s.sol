// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {ReleaseManifest} from "./ReleaseManifest.sol";

/// @notice Read-only release verification driven only by a reviewed manifest.
contract VerifyDeployment is ReleaseManifest {
    function run() external view {
        Manifest memory manifest = _loadManifest();
        DeploymentValidation.Stack memory deployment = manifest.stack;

        bool dependencyPaused = vm.envOr("EXTERNAL_DEPENDENCY_PAUSED", false);
        if (dependencyPaused) {
            _validatePausedManifestCore(manifest, true);
        } else {
            _validateManifestCore(manifest);
        }

        if (vm.envBool("DEPLOYMENT_ACTIVE")) {
            DeploymentValidation.validateOperationalState(deployment);
        } else {
            DeploymentValidation.validateDarkState(deployment);
        }

        DeploymentValidation.validateAcceptedAdmins(
            DeploymentValidation.adminContracts(deployment), manifest.admin, manifest.governance
        );
        // Direct token transfers cannot be prevented. These observations are
        // archived but are not activation failures; settlement preserves them.
        console.log("X402Adapter USDC balance:", IERC20(deployment.usdc).balanceOf(deployment.x402Adapter));
        console.log("PaymentRouter USDC balance:", IERC20(deployment.usdc).balanceOf(deployment.router));
        console.log("Release manifest hash:");
        console.logBytes32(manifest.hash);
        console.log("Effective release hash:");
        console.logBytes32(_effectiveReleaseHash(manifest));
    }
}
