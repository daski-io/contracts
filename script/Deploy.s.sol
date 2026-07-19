// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AgentIndex} from "../src/AgentIndex.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {PermitAdapter} from "../src/adapters/PermitAdapter.sol";
import {ApprovalAdapter} from "../src/adapters/ApprovalAdapter.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";

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

    string internal constant OUTCOME_SCHEMA = "uint256 paymentId,uint8 outcome";
    string internal constant CONFIRMATION_SCHEMA = "uint256 paymentId,uint8 confirmation";

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        require(treasury != address(0), "TREASURY_ADDRESS is required");

        // The canonical ERC-8004 IdentityRegistry for this chain. Required —
        // there is deliberately no fallback that deploys a local registry.
        address identityRegistry = vm.envOr("IDENTITY_REGISTRY_ADDRESS", address(0));
        require(
            identityRegistry != address(0),
            "IDENTITY_REGISTRY_ADDRESS not set. Use the canonical ERC-8004 registry: Base mainnet 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432, Base Sepolia 0x8004A818BFB912233c491871b3d84c89A494BD9e"
        );
        require(identityRegistry.code.length > 0, "IDENTITY_REGISTRY_ADDRESS has no code on this chain");

        address usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
        uint256 listingFee = vm.envOr("LISTING_FEE", uint256(1_000_000));
        uint256 commissionBps = vm.envOr("COMMISSION_BPS", uint256(500));

        address easAddress = vm.envOr("EAS_ADDRESS", DEFAULT_EAS);
        address schemaRegistryAddress = vm.envOr("EAS_SCHEMA_REGISTRY_ADDRESS", DEFAULT_SCHEMA_REGISTRY);
        require(easAddress.code.length > 0, "EAS_ADDRESS has no code");
        require(schemaRegistryAddress.code.length > 0, "EAS_SCHEMA_REGISTRY_ADDRESS has no code");
        if (usdcAddress != address(0)) {
            require(usdcAddress.code.length > 0, "USDC_ADDRESS has no code");
        }

        address deployer = vm.addr(deployerKey);
        // Final admin for every proxy. It must be an already-deployed
        // governance contract (multisig or timelock); an EOA deployer is
        // deliberately never accepted as the long-term control plane.
        address finalAdmin = vm.envOr("ADMIN_ADDRESS", address(0));
        require(finalAdmin != address(0), "ADMIN_ADDRESS is required");
        require(finalAdmin != deployer, "ADMIN_ADDRESS must differ from deployer");
        require(finalAdmin.code.length > 0, "ADMIN_ADDRESS must be a governance contract");

        console.log("Deployer:", deployer);
        console.log("Final admin:", finalAdmin);
        console.log("Treasury:", treasury);
        console.log("Canonical IdentityRegistry:", identityRegistry);
        console.log("EAS:     ", easAddress);
        console.log("SchemaRegistry:", schemaRegistryAddress);

        vm.startBroadcast(deployerKey);

        // ── (a) USDC ──────────────────────────────────────────────────
        if (usdcAddress == address(0)) {
            MockUSDC mockUsdc = new MockUSDC();
            usdcAddress = address(mockUsdc);
            console.log("MockUSDC deployed:", usdcAddress);
        } else {
            console.log("Using existing USDC:", usdcAddress);
        }

        // ── (b) AgentIndex (Daski companion to the canonical registry) ─
        AgentIndex agentIndexImpl = new AgentIndex();
        ERC1967Proxy agentIndexProxy = new ERC1967Proxy(
            address(agentIndexImpl), abi.encodeCall(AgentIndex.initialize, (identityRegistry, deployer))
        );
        console.log("AgentIndex impl:", address(agentIndexImpl));
        console.log("AgentIndex proxy:", address(agentIndexProxy));

        // ── (c) ValidationRegistry (ERC-8004, Daski-hosted) ───────────
        // Stays self-hosted: the ERC-8004 Validation Registry spec section is
        // still in flux and has no canonical deployment yet.
        ValidationRegistry validationRegistryImpl = new ValidationRegistry();
        ERC1967Proxy validationRegistryProxy = new ERC1967Proxy(
            address(validationRegistryImpl), abi.encodeCall(ValidationRegistry.initialize, (identityRegistry, deployer))
        );
        console.log("ValidationRegistry impl:", address(validationRegistryImpl));
        console.log("ValidationRegistry proxy:", address(validationRegistryProxy));

        // ── (d) ProviderRegistry (Daski) ──────────────────────────────
        ProviderRegistry providerRegistryImpl = new ProviderRegistry();
        ERC1967Proxy providerRegistryProxy = new ERC1967Proxy(
            address(providerRegistryImpl),
            abi.encodeCall(ProviderRegistry.initialize, (identityRegistry, usdcAddress, treasury, listingFee, deployer))
        );
        console.log("ProviderRegistry impl:", address(providerRegistryImpl));
        console.log("ProviderRegistry proxy:", address(providerRegistryProxy));

        // ── (e) ServiceRegistry (Daski) ───────────────────────────────
        ServiceRegistry serviceRegistryImpl = new ServiceRegistry();
        ERC1967Proxy serviceRegistryProxy = new ERC1967Proxy(
            address(serviceRegistryImpl),
            abi.encodeCall(ServiceRegistry.initialize, (identityRegistry, address(providerRegistryProxy), deployer))
        );
        console.log("ServiceRegistry impl:", address(serviceRegistryImpl));
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
                    treasury,
                    commissionBps,
                    deployer
                )
            )
        );
        PaymentRouter router = PaymentRouter(address(routerProxy));
        console.log("PaymentRouter impl:", address(routerImpl));
        console.log("PaymentRouter proxy:", address(routerProxy));

        // ── (g) ReputationStorage (EAS resolver + refund sink) ────────
        ReputationStorage reputationImpl = new ReputationStorage();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl), abi.encodeCall(ReputationStorage.initialize, (address(routerProxy), deployer))
        );
        ReputationStorage reputation = ReputationStorage(address(reputationProxy));
        console.log("ReputationStorage impl:", address(reputationImpl));
        console.log("ReputationStorage proxy:", address(reputationProxy));

        // Register the two EAS schemas against this resolver.
        ISchemaRegistry schemaRegistry = ISchemaRegistry(schemaRegistryAddress);
        bytes32 outcomeSchemaUid = schemaRegistry.register(OUTCOME_SCHEMA, address(reputationProxy), false);
        bytes32 confirmationSchemaUid = schemaRegistry.register(CONFIRMATION_SCHEMA, address(reputationProxy), true);

        reputation.setEAS(easAddress);
        reputation.setOutcomeSchema(outcomeSchemaUid);
        reputation.setConfirmationSchema(confirmationSchemaUid);

        // ── (h) X402Adapter ───────────────────────────────────────────
        X402Adapter x402AdapterImpl = new X402Adapter();
        ERC1967Proxy x402AdapterProxy = new ERC1967Proxy(
            address(x402AdapterImpl),
            abi.encodeCall(X402Adapter.initialize, (address(routerProxy), address(agentIndexProxy), deployer))
        );
        console.log("X402Adapter impl:", address(x402AdapterImpl));
        console.log("X402Adapter proxy:", address(x402AdapterProxy));

        // ── (i) PermitAdapter ─────────────────────────────────────────
        PermitAdapter permitAdapterImpl = new PermitAdapter();
        ERC1967Proxy permitAdapterProxy = new ERC1967Proxy(
            address(permitAdapterImpl),
            abi.encodeCall(PermitAdapter.initialize, (address(routerProxy), address(agentIndexProxy), deployer))
        );
        console.log("PermitAdapter impl:", address(permitAdapterImpl));
        console.log("PermitAdapter proxy:", address(permitAdapterProxy));

        // ── (j) ApprovalAdapter ───────────────────────────────────────
        ApprovalAdapter approvalAdapterImpl = new ApprovalAdapter();
        ERC1967Proxy approvalAdapterProxy = new ERC1967Proxy(
            address(approvalAdapterImpl),
            abi.encodeCall(ApprovalAdapter.initialize, (address(routerProxy), address(agentIndexProxy), deployer))
        );
        console.log("ApprovalAdapter impl:", address(approvalAdapterImpl));
        console.log("ApprovalAdapter proxy:", address(approvalAdapterProxy));

        // ── (k) Wire reputation before enabling payment entry points ──
        router.setReputationStorage(address(reputationProxy));
        router.setAdapter(address(x402AdapterProxy), true);
        router.setAdapter(address(permitAdapterProxy), true);
        router.setAdapter(address(approvalAdapterProxy), true);
        router.setAcceptedToken(usdcAddress, true);

        // ── (l) Admin handoff ─────────────────────────────────────────
        // All wiring above ran as the deployer. Start the mandatory two-step
        // handoff for every proxy; governance must accept each pending role
        // before the deployment is considered operational.
        address[9] memory adminContracts = [
            address(agentIndexProxy),
            address(validationRegistryProxy),
            address(providerRegistryProxy),
            address(serviceRegistryProxy),
            address(routerProxy),
            address(reputationProxy),
            address(x402AdapterProxy),
            address(permitAdapterProxy),
            address(approvalAdapterProxy)
        ];
        for (uint256 i = 0; i < adminContracts.length; i++) {
            Admin2StepUpgradeable(adminContracts[i]).transferAdmin(finalAdmin);
        }
        console.log("Admin transfer started to:", finalAdmin);
        console.log("  governance MUST call acceptAdmin() on each proxy");

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────
        console.log("-------------------------------------------");
        console.log("Deployment broadcast complete; admin acceptance pending");
        console.log("  USDC:               ", usdcAddress);
        console.log("  IdentityRegistry (canonical, external):", identityRegistry);
        console.log("  AgentIndex:         ", address(agentIndexProxy));
        console.log("  ValidationRegistry: ", address(validationRegistryProxy));
        console.log("  ProviderRegistry:   ", address(providerRegistryProxy));
        console.log("  ServiceRegistry:    ", address(serviceRegistryProxy));
        console.log("  PaymentRouter:      ", address(routerProxy));
        console.log("  ReputationStorage:  ", address(reputationProxy));
        console.log("  X402Adapter:        ", address(x402AdapterProxy));
        console.log("  PermitAdapter:      ", address(permitAdapterProxy));
        console.log("  ApprovalAdapter:    ", address(approvalAdapterProxy));
        console.log("  EAS:                ", easAddress);
        console.log("  SchemaRegistry:     ", schemaRegistryAddress);
        console.log("  Outcome schema UID:");
        console.logBytes32(outcomeSchemaUid);
        console.log("  Confirmation schema UID:");
        console.logBytes32(confirmationSchemaUid);
        console.log("-------------------------------------------");
    }
}
