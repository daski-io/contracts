// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SafeDeployment} from "./SafeDeployment.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {GovernanceBatches} from "./GovernanceBatches.sol";

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
///         those into the Safe app instead. Stack addresses come from the
///         same env names VerifyDeployment.s.sol reads.
contract ExecuteGovernanceBatches is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(deployerKey);
        address safe = vm.envAddress("ADMIN_ADDRESS");
        string memory batch = vm.envString("GOVERNANCE_BATCH");

        SafeDeployment.validateCanonicalDeployment();
        DeploymentValidation.Stack memory deployment = DeploymentValidation.Stack({
            identity: vm.envAddress("IDENTITY_REGISTRY_ADDRESS"),
            usdc: vm.envAddress("USDC_ADDRESS"),
            providerTreasury: vm.envAddress("PROVIDER_TREASURY_ADDRESS"),
            paymentTreasury: vm.envAddress("PAYMENT_TREASURY_ADDRESS"),
            sanctionsOracle: vm.envAddress("SANCTIONS_ORACLE_ADDRESS"),
            agentIndex: vm.envAddress("AGENT_INDEX_ADDRESS"),
            daskiValidationRegistry: vm.envAddress("DASKI_VALIDATION_REGISTRY_ADDRESS"),
            providerRegistry: vm.envAddress("PROVIDER_REGISTRY_ADDRESS"),
            serviceRegistry: vm.envAddress("SERVICE_REGISTRY_ADDRESS"),
            router: vm.envAddress("PAYMENT_ROUTER_ADDRESS"),
            reputation: vm.envAddress("REPUTATION_STORAGE_ADDRESS"),
            x402Adapter: vm.envAddress("X402_ADAPTER_ADDRESS"),
            permitAdapter: vm.envAddress("PERMIT_ADAPTER_ADDRESS"),
            approvalAdapter: vm.envAddress("APPROVAL_ADAPTER_ADDRESS"),
            listingFee: vm.envOr("LISTING_FEE", uint256(1_000_000)),
            commissionBps: vm.envOr("COMMISSION_BPS", uint256(500)),
            reputationMinimum: vm.envOr("USDC_REPUTATION_MINIMUM", uint256(250_000))
        });

        address[] memory targets;
        bytes[] memory calls;
        bytes32 batchId = keccak256(bytes(batch));
        if (batchId == keccak256("accept")) {
            DeploymentValidation.validatePendingAdmins(DeploymentValidation.adminContracts(deployment), sender, safe);
            (targets, calls) = GovernanceBatches.adminAcceptance(deployment);
        } else if (batchId == keccak256("activate")) {
            DeploymentValidation.validateAcceptedAdmins(DeploymentValidation.adminContracts(deployment), safe);
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
            DeploymentValidation.validateAcceptedAdmins(DeploymentValidation.adminContracts(deployment), safe);
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
