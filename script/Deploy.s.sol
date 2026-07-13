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
import {DirectTransferAdapter} from "../src/adapters/DirectTransferAdapter.sol";
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
///         The script also registers the two EAS schemas the
///         ReputationStorage resolver listens to; schema UIDs are logged at
///         the end so CI / ops can paste them into the off-chain services'
///         env files.
contract Deploy is Script {
    address internal constant DEFAULT_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant DEFAULT_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    string internal constant OUTCOME_SCHEMA = "uint256 paymentId,uint8 outcome";
    string internal constant CONFIRMATION_SCHEMA = "uint256 paymentId,uint8 confirmation";

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

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

        address deployer = vm.addr(deployerKey);

        // Final admin for all proxies. Defaults to the deployer (testnet
        // convenience). For mainnet set ADMIN_ADDRESS to a multisig or a
        // TimelockController: the script deploys + wires as the deployer, then
        // hands off via the 2-step transferAdmin below (the new admin must call
        // acceptAdmin() on each contract to complete the handover).
        address finalAdmin = vm.envOr("ADMIN_ADDRESS", deployer);

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
            address(reputationImpl),
            abi.encodeCall(ReputationStorage.initialize, (identityRegistry, address(routerProxy), deployer))
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

        // ── (k) DirectTransferAdapter (external-facilitator rail) ─────
        // Attributes payments settled by an external x402 facilitator (CDP)
        // as bare EIP-3009 transfers into the router. ATTRIBUTOR_ADDRESS is
        // the gateway's facilitator wallet; when unset, ops must call
        // setAttributor before the external rail can settle anything.
        DirectTransferAdapter directAdapterImpl = new DirectTransferAdapter();
        ERC1967Proxy directAdapterProxy = new ERC1967Proxy(
            address(directAdapterImpl),
            abi.encodeCall(DirectTransferAdapter.initialize, (address(routerProxy), address(agentIndexProxy), deployer))
        );
        console.log("DirectTransferAdapter impl:", address(directAdapterImpl));
        console.log("DirectTransferAdapter proxy:", address(directAdapterProxy));

        address attributor = vm.envOr("ATTRIBUTOR_ADDRESS", address(0));
        if (attributor != address(0)) {
            DirectTransferAdapter(address(directAdapterProxy)).setAttributor(attributor, true);
            console.log("Attributor whitelisted:", attributor);
        }

        // ── (l) Wire whitelists ───────────────────────────────────────
        router.setAdapter(address(x402AdapterProxy), true);
        router.setAdapter(address(permitAdapterProxy), true);
        router.setAdapter(address(approvalAdapterProxy), true);
        router.setAdapter(address(directAdapterProxy), true);
        router.setAcceptedToken(usdcAddress, true);
        router.setReputationStorage(address(reputationProxy));

        // ── (m) Admin handoff ─────────────────────────────────────────
        // All wiring above is onlyAdmin and ran as the deployer. If a separate
        // ADMIN_ADDRESS (multisig / timelock) was supplied, start the 2-step
        // transfer for every proxy now; the new admin completes it by calling
        // acceptAdmin() on each. Until then the deployer stays admin, so a
        // mistyped address is recoverable.
        if (finalAdmin != deployer) {
            address[10] memory adminContracts = [
                address(agentIndexProxy),
                address(validationRegistryProxy),
                address(providerRegistryProxy),
                address(serviceRegistryProxy),
                address(routerProxy),
                address(reputationProxy),
                address(x402AdapterProxy),
                address(permitAdapterProxy),
                address(approvalAdapterProxy),
                address(directAdapterProxy)
            ];
            for (uint256 i = 0; i < adminContracts.length; i++) {
                Admin2StepUpgradeable(adminContracts[i]).transferAdmin(finalAdmin);
            }
            console.log("Admin transfer started to:", finalAdmin);
            console.log("  new admin MUST call acceptAdmin() on each proxy to complete handover");
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────
        console.log("-------------------------------------------");
        console.log("Deployment complete");
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
        console.log("  DirectTransferAdapter:", address(directAdapterProxy));
        console.log("  EAS:                ", easAddress);
        console.log("  SchemaRegistry:     ", schemaRegistryAddress);
        console.log("  Outcome schema UID:");
        console.logBytes32(outcomeSchemaUid);
        console.log("  Confirmation schema UID:");
        console.logBytes32(confirmationSchemaUid);
        console.log("-------------------------------------------");
    }
}
