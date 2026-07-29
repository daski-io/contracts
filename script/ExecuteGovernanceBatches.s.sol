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
    struct RunContext {
        bool emitOnly;
        uint256 deployerKey;
        address sender;
        string batch;
        bytes32 batchId;
    }

    function run() external {
        RunContext memory context = _runContext();
        Manifest memory manifest = _loadManifest();
        SafeDeployment.validateCanonicalDeployment();
        (address[] memory targets, bytes[] memory calls) = _governanceCalls(context, manifest);

        _logBatch(context.batch, targets, calls);
        if (context.emitOnly) {
            console.log("Payload emitted without execution for manifest:");
            console.logBytes32(manifest.hash);
            console.log("Effective release hash:");
            console.logBytes32(_effectiveReleaseHash(manifest));
            return;
        }

        vm.startBroadcast(context.deployerKey);
        SafeDeployment.execMultiSendBatch(manifest.admin, context.sender, targets, calls);
        vm.stopBroadcast();
        _validateExecutedBatch(context.batchId, manifest);
    }

    function _runContext() private view returns (RunContext memory context) {
        context.emitOnly = vm.envOr("EMIT_ONLY", false);
        if (context.emitOnly) {
            context.sender = vm.envAddress("GOVERNANCE_SENDER");
        } else {
            context.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
            context.sender = vm.addr(context.deployerKey);
        }
        context.batch = vm.envString("GOVERNANCE_BATCH");
        context.batchId = keccak256(bytes(context.batch));
    }

    function _governanceCalls(RunContext memory context, Manifest memory manifest)
        private
        view
        returns (address[] memory targets, bytes[] memory calls)
    {
        DeploymentValidation.Stack memory deployment = manifest.stack;
        if (context.batchId == keccak256("guardian")) {
            _validateGuardianConfigurationCore(manifest);
        } else if (context.batchId == keccak256("pause")) {
            _validatePausedManifestCore(manifest, false);
        } else if (context.batchId == keccak256("unpause")) {
            _validateUnpauseManifestCore(manifest);
        } else {
            _validateManifestCore(manifest);
        }

        if (context.batchId == keccak256("accept")) {
            DeploymentValidation.validateDarkState(deployment);
            DeploymentValidation.validatePendingAdmins(
                DeploymentValidation.adminContracts(deployment), context.sender, manifest.admin, manifest.governance
            );
            return GovernanceBatches.adminAcceptance(deployment);
        }
        DeploymentValidation.validateAcceptedAdmins(
            DeploymentValidation.adminContracts(deployment), manifest.admin, manifest.governance
        );
        if (context.batchId == keccak256("guardian")) {
            return GovernanceBatches.pauseGuardianConfiguration(deployment, manifest.pauseGuardian);
        }
        if (context.batchId == keccak256("activate")) {
            DeploymentValidation.validateDarkState(deployment);
            return GovernanceBatches.paymentActivation(deployment);
        }
        if (context.batchId == keccak256("pause")) {
            return GovernanceBatches.externalDependencyPause(deployment);
        }
        if (context.batchId == keccak256("unpause")) {
            return GovernanceBatches.externalDependencyUnpause(deployment);
        }
        revert("unsupported governance batch");
    }

    function _validateExecutedBatch(bytes32 batchId, Manifest memory manifest) private view {
        DeploymentValidation.Stack memory deployment = manifest.stack;
        if (batchId == keccak256("accept")) {
            DeploymentValidation.validateAcceptedAdmins(
                DeploymentValidation.adminContracts(deployment), manifest.admin, manifest.governance
            );
            console.log("Batch 1 executed: all nine admin roles accepted by", manifest.admin);
        } else if (batchId == keccak256("guardian")) {
            _validateManifestCore(manifest);
            console.log("Pause guardian configuration executed");
        } else if (batchId == keccak256("activate")) {
            DeploymentValidation.validateOperationalState(deployment);
            console.log("Batch 2 executed: token + adapters active; deployment operational");
        } else if (batchId == keccak256("pause")) {
            _validatePausedManifestCore(manifest, true);
            console.log("External dependency pause executed");
        } else {
            _validateManifestCore(manifest);
            DeploymentValidation.validateOperationalState(deployment);
            console.log("External dependency unpause executed");
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
