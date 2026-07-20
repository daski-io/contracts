// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";

/// @notice Read-only verification for a deployed stack after governance has
///         accepted every two-step admin transfer.
contract VerifyDeployment is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        address identity = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address eas = vm.envAddress("EAS_ADDRESS");
        address schemaRegistry = vm.envAddress("EAS_SCHEMA_REGISTRY_ADDRESS");
        address finalAdmin = vm.envAddress("ADMIN_ADDRESS");
        bool deploymentActive = vm.envBool("DEPLOYMENT_ACTIVE");

        DeploymentValidation.validateExternalDependencies(
            identity, usdc, eas, schemaRegistry, vm.envOr("ALLOW_UNSUPPORTED_CHAIN", false)
        );

        DeploymentValidation.Stack memory deployment = DeploymentValidation.Stack({
            identity: identity,
            usdc: usdc,
            providerTreasury: vm.envAddress("PROVIDER_TREASURY_ADDRESS"),
            paymentTreasury: vm.envAddress("PAYMENT_TREASURY_ADDRESS"),
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

        DeploymentValidation.validateSchemas(
            eas,
            schemaRegistry,
            deployment.reputation,
            vm.envBytes32("OUTCOME_SCHEMA_UID"),
            vm.envBytes32("CONFIRMATION_SCHEMA_UID"),
            DeploymentValidation.outcomeSchema(),
            DeploymentValidation.confirmationSchema()
        );
        DeploymentValidation.validateCoreWiring(deployment);
        if (deploymentActive) {
            DeploymentValidation.validateOperationalState(deployment);
        } else {
            DeploymentValidation.validateDarkState(deployment);
        }

        DeploymentValidation.validateAcceptedAdmins(DeploymentValidation.adminContracts(deployment), finalAdmin);
        _validateImplementation(deployment.agentIndex, "AGENT_INDEX_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.daskiValidationRegistry, "DASKI_VALIDATION_REGISTRY_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.providerRegistry, "PROVIDER_REGISTRY_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.serviceRegistry, "SERVICE_REGISTRY_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.router, "PAYMENT_ROUTER_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.reputation, "REPUTATION_STORAGE_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.x402Adapter, "X402_ADAPTER_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.permitAdapter, "PERMIT_ADAPTER_IMPLEMENTATION_CODEHASH");
        _validateImplementation(deployment.approvalAdapter, "APPROVAL_ADAPTER_IMPLEMENTATION_CODEHASH");
    }

    function _validateImplementation(address proxy, string memory codehashEnv) private view {
        address implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(implementation.code.length > 0, "implementation has no code");
        require(implementation.codehash == vm.envBytes32(codehashEnv), "implementation codehash mismatch");
        require(IERC1822Proxiable(implementation).proxiableUUID() == IMPLEMENTATION_SLOT, "implementation not UUPS");
    }
}
