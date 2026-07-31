// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AgentIndex} from "../src/AgentIndex.sol";
import {DaskiValidationRegistry} from "../src/DaskiValidationRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {PermitAdapter} from "../src/adapters/PermitAdapter.sol";
import {ApprovalAdapter} from "../src/adapters/ApprovalAdapter.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {SafeDeployment} from "./SafeDeployment.sol";

/// @notice Deploy the Daski stack against the CANONICAL ERC-8004
///         IdentityRegistry — Daski deploys no identity registry (and no
///         ERC-8004 reputation registry) of its own anymore.
///
///         IDENTITY_REGISTRY_ADDRESS must point at the canonical per-chain
///         singleton:
///           Base mainnet  0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
///           Base Sepolia  0x8004A818BFB912233c491871b3d84c89A494BD9e
///
///         Public ERC-8004 feedback lives in the canonical
///         ReputationRegistry (Base mainnet 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63,
///         Base Sepolia 0x8004B663056A597Dffe9eCcC1965A193B7388713), written
///         by the gateway off-chain; no contract in this stack touches it.
///
///         The script registers both EAS schemas and logs their UIDs for
///         off-chain service configuration.
contract Deploy is Script {
    address internal constant DEFAULT_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant DEFAULT_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address providerTreasury = vm.envAddress("PROVIDER_TREASURY_ADDRESS");
        require(providerTreasury != address(0), "PROVIDER_TREASURY_ADDRESS is required");
        address paymentTreasury = vm.envAddress("PAYMENT_TREASURY_ADDRESS");
        require(paymentTreasury != address(0), "PAYMENT_TREASURY_ADDRESS is required");
        address facilitator = vm.envAddress("FACILITATOR_ADDRESS");
        require(facilitator != address(0), "FACILITATOR_ADDRESS is required");

        // The canonical ERC-8004 IdentityRegistry for this chain. Required —
        // there is deliberately no fallback that deploys a local registry.
        address identityRegistry = vm.envOr("IDENTITY_REGISTRY_ADDRESS", address(0));
        require(
            identityRegistry != address(0),
            "IDENTITY_REGISTRY_ADDRESS not set. Use the canonical ERC-8004 registry: Base mainnet 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432, Base Sepolia 0x8004A818BFB912233c491871b3d84c89A494BD9e"
        );
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        require(usdcAddress != address(0), "USDC_ADDRESS is required");
        address sanctionsOracleAddress = vm.envAddress("SANCTIONS_ORACLE_ADDRESS");
        require(sanctionsOracleAddress != address(0), "SANCTIONS_ORACLE_ADDRESS is required");
        uint256 listingFee = vm.envOr("LISTING_FEE", uint256(1_000_000));
        uint256 commissionBps = vm.envOr("COMMISSION_BPS", uint256(500));

        address easAddress = vm.envOr("EAS_ADDRESS", DEFAULT_EAS);
        address schemaRegistryAddress = vm.envOr("EAS_SCHEMA_REGISTRY_ADDRESS", DEFAULT_SCHEMA_REGISTRY);
        DeploymentValidation.validateExternalDependencies(
            identityRegistry,
            usdcAddress,
            easAddress,
            schemaRegistryAddress,
            sanctionsOracleAddress,
            vm.envOr("ALLOW_UNSUPPORTED_CHAIN", false),
            vm.envOr("ALLOW_MOCK_SANCTIONS_ORACLE", false)
        );

        address deployer = vm.addr(deployerKey);
        // Final admin for every proxy. It must match the exact canonical Safe
        // profile supplied for this deployment; an EOA or arbitrary contract
        // is never accepted as the long-term control plane.
        address finalAdmin = vm.envOr("ADMIN_ADDRESS", address(0));
        SafeDeployment.Profile memory governance = _governanceProfile(deployer);
        DeploymentValidation.validateFinalAdmin(finalAdmin, deployer, governance);

        vm.startBroadcast(deployerKey);

        console.log("Using existing USDC:", usdcAddress);

        // ── (b) AgentIndex (Daski companion to the canonical registry) ─
        AgentIndex agentIndexImpl = new AgentIndex();
        ERC1967Proxy agentIndexProxy = new ERC1967Proxy(
            address(agentIndexImpl),
            abi.encodeCall(AgentIndex.initialize, (identityRegistry, sanctionsOracleAddress, deployer))
        );
        console.log("AgentIndex proxy:", address(agentIndexProxy));

        // ── (c) DaskiValidationRegistry ───────────────────────────────
        // Namespaced request keys and paginated reads intentionally differ
        // from the draft ERC-8004 validation surface.
        DaskiValidationRegistry validationRegistryImpl = new DaskiValidationRegistry();
        ERC1967Proxy validationRegistryProxy = new ERC1967Proxy(
            address(validationRegistryImpl),
            abi.encodeCall(DaskiValidationRegistry.initialize, (identityRegistry, sanctionsOracleAddress, deployer))
        );
        console.log("DaskiValidationRegistry proxy:", address(validationRegistryProxy));

        // ── (d) ProviderRegistry (Daski) ──────────────────────────────
        ProviderRegistry providerRegistryImpl = new ProviderRegistry();
        ERC1967Proxy providerRegistryProxy = new ERC1967Proxy(
            address(providerRegistryImpl),
            abi.encodeCall(
                ProviderRegistry.initialize,
                (identityRegistry, usdcAddress, providerTreasury, listingFee, sanctionsOracleAddress, deployer)
            )
        );
        console.log("ProviderRegistry proxy:", address(providerRegistryProxy));

        // ── (e) ServiceRegistry (Daski) ───────────────────────────────
        ServiceRegistry serviceRegistryImpl = new ServiceRegistry();
        ERC1967Proxy serviceRegistryProxy = new ERC1967Proxy(
            address(serviceRegistryImpl),
            abi.encodeCall(
                ServiceRegistry.initialize,
                (identityRegistry, address(providerRegistryProxy), sanctionsOracleAddress, deployer)
            )
        );
        console.log("ServiceRegistry proxy:", address(serviceRegistryProxy));

        // ── (f) PaymentRouter (Daski) ─────────────────────────────────
        PaymentRouter routerImpl = new PaymentRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PaymentRouter.initialize,
                (
                    identityRegistry,
                    address(providerRegistryProxy),
                    address(serviceRegistryProxy),
                    paymentTreasury,
                    commissionBps,
                    sanctionsOracleAddress,
                    deployer
                )
            )
        );
        PaymentRouter router = PaymentRouter(address(routerProxy));
        console.log("PaymentRouter proxy:", address(routerProxy));

        // ── (g) ReputationStorage (EAS resolver + refund sink) ────────
        ReputationStorage reputationImpl = new ReputationStorage();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(ReputationStorage.initialize, (address(routerProxy), sanctionsOracleAddress, deployer))
        );
        ReputationStorage reputation = ReputationStorage(address(reputationProxy));
        console.log("ReputationStorage proxy:", address(reputationProxy));

        // Register the two EAS schemas against this resolver.
        ISchemaRegistry schemaRegistry = ISchemaRegistry(schemaRegistryAddress);
        string memory outcomeSchema = DeploymentValidation.outcomeSchema();
        string memory confirmationSchema = DeploymentValidation.confirmationSchema();
        bytes32 outcomeSchemaUid = schemaRegistry.register(outcomeSchema, address(reputationProxy), false);
        bytes32 confirmationSchemaUid = schemaRegistry.register(confirmationSchema, address(reputationProxy), true);

        reputation.setEAS(easAddress);
        reputation.setOutcomeSchema(outcomeSchemaUid);
        reputation.setConfirmationSchema(confirmationSchemaUid);
        reputation.finalizeConfiguration();
        DeploymentValidation.validateSchemas(
            easAddress,
            schemaRegistryAddress,
            address(reputationProxy),
            outcomeSchemaUid,
            confirmationSchemaUid,
            outcomeSchema,
            confirmationSchema
        );

        // ── (h) X402Adapter ───────────────────────────────────────────
        X402Adapter x402AdapterImpl = new X402Adapter();
        ERC1967Proxy x402AdapterProxy = new ERC1967Proxy(
            address(x402AdapterImpl),
            abi.encodeCall(
                X402Adapter.initialize,
                (address(routerProxy), address(agentIndexProxy), sanctionsOracleAddress, deployer)
            )
        );
        console.log("X402Adapter proxy:", address(x402AdapterProxy));
        X402Adapter(address(x402AdapterProxy)).setFacilitatorAuthorization(facilitator, true);
        console.log("X402 facilitator:", facilitator);

        // ── (i) PermitAdapter ─────────────────────────────────────────
        PermitAdapter permitAdapterImpl = new PermitAdapter();
        ERC1967Proxy permitAdapterProxy = new ERC1967Proxy(
            address(permitAdapterImpl),
            abi.encodeCall(
                PermitAdapter.initialize,
                (address(routerProxy), address(agentIndexProxy), sanctionsOracleAddress, deployer)
            )
        );
        console.log("PermitAdapter proxy:", address(permitAdapterProxy));

        // ── (j) ApprovalAdapter ───────────────────────────────────────
        ApprovalAdapter approvalAdapterImpl = new ApprovalAdapter();
        ERC1967Proxy approvalAdapterProxy = new ERC1967Proxy(
            address(approvalAdapterImpl),
            abi.encodeCall(
                ApprovalAdapter.initialize,
                (address(routerProxy), address(agentIndexProxy), sanctionsOracleAddress, deployer)
            )
        );
        console.log("ApprovalAdapter proxy:", address(approvalAdapterProxy));

        // ── (k) Wire reputation; payment entry points remain dark ─────
        router.setReputationStorage(address(reputationProxy));

        DeploymentValidation.Stack memory deployment = DeploymentValidation.Stack({
            identity: identityRegistry,
            usdc: usdcAddress,
            providerTreasury: providerTreasury,
            paymentTreasury: paymentTreasury,
            sanctionsOracle: sanctionsOracleAddress,
            agentIndex: address(agentIndexProxy),
            daskiValidationRegistry: address(validationRegistryProxy),
            providerRegistry: address(providerRegistryProxy),
            serviceRegistry: address(serviceRegistryProxy),
            router: address(routerProxy),
            reputation: address(reputationProxy),
            x402Adapter: address(x402AdapterProxy),
            permitAdapter: address(permitAdapterProxy),
            approvalAdapter: address(approvalAdapterProxy),
            listingFee: listingFee,
            commissionBps: commissionBps,
            reputationMinimum: vm.envOr("USDC_REPUTATION_MINIMUM", uint256(250_000))
        });
        _configurePauseGuardians(deployment, governance.releaseCandidate);
        DeploymentValidation.validateCoreWiring(deployment);
        DeploymentValidation.validateDarkState(deployment);

        // ── (l) Admin handoff ─────────────────────────────────────────
        // All wiring above ran as the deployer. Start the mandatory two-step
        // handoff for every proxy; governance must accept each pending role
        // before the deployment is considered operational.
        address[9] memory adminContracts = DeploymentValidation.adminContracts(deployment);
        for (uint256 i = 0; i < adminContracts.length; i++) {
            Admin2StepUpgradeable(adminContracts[i]).transferAdmin(finalAdmin);
        }
        DeploymentValidation.validatePendingAdmins(adminContracts, deployer, finalAdmin, governance);
        console.log("Admin transfer started to:", finalAdmin);
        console.log("  governance MUST call acceptAdmin() on each proxy");

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────
        console.log("-------------------------------------------");
        console.log("Deployment broadcast complete; admin acceptance pending");
        console.log("  USDC:               ", usdcAddress);
        console.log("  SanctionsOracle:    ", sanctionsOracleAddress);
        console.log("  IdentityRegistry (canonical, external):", identityRegistry);
        console.log("  AgentIndex:         ", address(agentIndexProxy));
        console.log("  DaskiValidationRegistry:", address(validationRegistryProxy));
        console.log("  ProviderRegistry:   ", address(providerRegistryProxy));
        console.log("  ServiceRegistry:    ", address(serviceRegistryProxy));
        console.log("  PaymentRouter:      ", address(routerProxy));
        console.log("  ReputationStorage:  ", address(reputationProxy));
        console.log("  X402Adapter:        ", address(x402AdapterProxy));
        console.log("  X402 facilitator:   ", facilitator);
        console.log("  PermitAdapter:      ", address(permitAdapterProxy));
        console.log("  ApprovalAdapter:    ", address(approvalAdapterProxy));
        _logImplementation("AgentIndex", address(agentIndexImpl));
        _logImplementation("DaskiValidationRegistry", address(validationRegistryImpl));
        _logImplementation("ProviderRegistry", address(providerRegistryImpl));
        _logImplementation("ServiceRegistry", address(serviceRegistryImpl));
        _logImplementation("PaymentRouter", address(routerImpl));
        _logImplementation("ReputationStorage", address(reputationImpl));
        _logImplementation("X402Adapter", address(x402AdapterImpl));
        _logImplementation("PermitAdapter", address(permitAdapterImpl));
        _logImplementation("ApprovalAdapter", address(approvalAdapterImpl));
        console.log("  EAS:                ", easAddress);
        console.log("  SchemaRegistry:     ", schemaRegistryAddress);
        console.log("  Outcome schema UID:");
        console.logBytes32(outcomeSchemaUid);
        console.log("  Confirmation schema UID:");
        console.logBytes32(confirmationSchemaUid);
        console.log("-------------------------------------------");
    }

    function _logImplementation(string memory name, address implementation) private view {
        console.log(string.concat("  ", name, " implementation:"), implementation);
        console.log("    codehash:");
        console.logBytes32(implementation.codehash);
    }

    function _configurePauseGuardians(DeploymentValidation.Stack memory deployment, bool releaseCandidate) private {
        address pauseGuardian = vm.envOr("PAUSE_GUARDIAN_ADDRESS", address(0));
        require(!releaseCandidate || pauseGuardian != address(0), "release guardian required");
        address[9] memory contracts_ = DeploymentValidation.adminContracts(deployment);
        if (pauseGuardian != address(0)) {
            for (uint256 i = 0; i < contracts_.length; i++) {
                Admin2StepUpgradeable(contracts_[i]).setPauseGuardian(pauseGuardian);
            }
        }
        DeploymentValidation.validateExternalDependencyGuards(contracts_, pauseGuardian, false);
    }

    function _governanceProfile(address deployer) private view returns (SafeDeployment.Profile memory profile) {
        address[] memory defaultOwners = new address[](1);
        defaultOwners[0] = deployer;
        address[] memory noModules = new address[](0);
        profile = SafeDeployment.Profile({
            owners: vm.envOr("SAFE_OWNERS", ",", defaultOwners),
            threshold: vm.envOr("SAFE_THRESHOLD", uint256(1)),
            modules: vm.envOr("SAFE_MODULES", ",", noModules),
            guard: vm.envOr("SAFE_GUARD", address(0)),
            fallbackHandler: SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER,
            releaseCandidate: vm.envOr("RELEASE_CANDIDATE", false)
        });
    }
}
