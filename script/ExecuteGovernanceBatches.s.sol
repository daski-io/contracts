// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {SafeDeployment} from "./SafeDeployment.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {GovernanceBatches} from "./GovernanceBatches.sol";
import {ReleaseManifest} from "./ReleaseManifest.sol";

/// @notice Drives the two staged-deployment governance batches through the
///         Safe configured as ADMIN_ADDRESS, one Safe transaction per batch
///         (delegatecall into canonical MultiSendCallOnly).
///
///         GOVERNANCE_BATCH=accept    batch 1 — acceptAdmin() on all nine
///                                    proxies; requires the pending-admin
///                                    state Deploy.s.sol leaves behind.
///         GOVERNANCE_BATCH=activate  batch 2 — accept USDC, configure token
///                                    reputation, enable the three adapters;
///                                    requires batch 1 and a dark router.
///
///         Execution is testnet automation: the broadcasting EOA must be an
///         owner of a 1-of-1 Safe. With a higher threshold the script logs
///         every call plus the packed MultiSend payload and reverts — feed
///         those into the Safe app instead. Stack identity comes from the
///         same reviewed release manifest VerifyDeployment.s.sol reads.
contract ExecuteGovernanceBatches is ReleaseManifest {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(deployerKey);
        string memory batch = vm.envString("GOVERNANCE_BATCH");
        Manifest memory manifest = _loadManifest();
        address safe = manifest.admin;
        DeploymentValidation.Stack memory deployment = manifest.stack;

        SafeDeployment.validateCanonicalDeployment();
        _validateManifestCore(manifest);

        address[] memory targets;
        bytes[] memory calls;
        bytes32 batchId = keccak256(bytes(batch));
        if (batchId == keccak256("accept")) {
            DeploymentValidation.validateDarkState(deployment);
            DeploymentValidation.validatePendingAdmins(
                DeploymentValidation.adminContracts(deployment), sender, safe, manifest.governance
            );
            (targets, calls) = GovernanceBatches.adminAcceptance(deployment);
        } else if (batchId == keccak256("activate")) {
            DeploymentValidation.validateAcceptedAdmins(
                DeploymentValidation.adminContracts(deployment), safe, manifest.governance
            );
            DeploymentValidation.validateDarkState(deployment);
            (targets, calls) = GovernanceBatches.paymentActivation(deployment);
        } else {
            revert("GOVERNANCE_BATCH must be accept or activate");
        }

        _logBatch(batch, targets, calls);

        vm.startBroadcast(deployerKey);
        SafeDeployment.execMultiSendBatch(safe, sender, targets, calls);
        vm.stopBroadcast();

        if (batchId == keccak256("accept")) {
            DeploymentValidation.validateAcceptedAdmins(
                DeploymentValidation.adminContracts(deployment), safe, manifest.governance
            );
            console.log("Batch 1 executed: all nine admin roles accepted by", safe);
        } else {
            DeploymentValidation.validateOperationalState(deployment);
            console.log("Batch 2 executed: token + adapters active; deployment operational");
        }
    }

    function _logBatch(string memory batch, address[] memory targets, bytes[] memory calls) private pure {
        console.log(string.concat("Governance batch '", batch, "' ("), targets.length, "calls):");
        for (uint256 i = 0; i < targets.length; i++) {
            console.log("  to:", targets[i]);
            console.logBytes(calls[i]);
        }
        console.log("MultiSendCallOnly payload (for the Safe app when threshold > 1):");
        console.log("  to:", SafeDeployment.MULTI_SEND_CALL_ONLY);
        console.log("  operation: 1 (delegatecall)");
        console.logBytes(SafeDeployment.packMultiSend(targets, calls));
    }
}
