// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {PermitAdapter} from "../src/adapters/PermitAdapter.sol";
import {ApprovalAdapter} from "../src/adapters/ApprovalAdapter.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";

/// @notice Deploy the full Daski stack. On Base Sepolia this also registers
///         the two EAS schemas the new ReputationStorage resolver listens
///         to; schema UIDs are logged at the end so CI / ops can paste them
///         into the off-chain services' env files.
contract Deploy is Script {
    // Canonical EAS deploys on Base and Base Sepolia (identical addresses
    // on both — confirmed via the EAS deployment table).
    address internal constant DEFAULT_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant DEFAULT_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    // EAS schema strings. The resolver decodes these via abi.decode in the
    // exact order listed here — DO NOT reorder fields without also updating
    // ReputationStorage._onOutcomeAttest / _onConfirmationAttest.
    string internal constant OUTCOME_SCHEMA = "uint256 paymentId,uint8 outcome,uint256 fulfillmentTime";
    string internal constant CONFIRMATION_SCHEMA = "uint256 paymentId,uint8 confirmation";

    function run() external {
        // ── Required env vars ──────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        // ── Optional env vars ──────────────────────────────────────────
        address usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
        uint256 listingFee = vm.envOr("LISTING_FEE", uint256(1_000_000)); // 1 USDC (6 decimals)
        uint256 commissionBps = vm.envOr("COMMISSION_BPS", uint256(500)); // 5%

        address easAddress = vm.envOr("EAS_ADDRESS", DEFAULT_EAS);
        address schemaRegistryAddress = vm.envOr("EAS_SCHEMA_REGISTRY_ADDRESS", DEFAULT_SCHEMA_REGISTRY);

        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
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

        // ── (b) IdentityRegistry (ERC-8004) ───────────────────────────
        IdentityRegistry identityImpl = new IdentityRegistry();
        ERC1967Proxy identityProxy =
            new ERC1967Proxy(address(identityImpl), abi.encodeCall(IdentityRegistry.initialize, (deployer)));
        console.log("IdentityRegistry impl:", address(identityImpl));
        console.log("IdentityRegistry proxy:", address(identityProxy));

        // ── (c) ReputationRegistry (ERC-8004) ─────────────────────────
        ReputationRegistry reputationRegistryImpl = new ReputationRegistry();
        ERC1967Proxy reputationRegistryProxy = new ERC1967Proxy(
            address(reputationRegistryImpl),
            abi.encodeCall(ReputationRegistry.initialize, (address(identityProxy), deployer))
        );
        console.log("ReputationRegistry impl:", address(reputationRegistryImpl));
        console.log("ReputationRegistry proxy:", address(reputationRegistryProxy));

        // ── (d) ValidationRegistry (ERC-8004) ─────────────────────────
        ValidationRegistry validationRegistryImpl = new ValidationRegistry();
        ERC1967Proxy validationRegistryProxy = new ERC1967Proxy(
            address(validationRegistryImpl),
            abi.encodeCall(ValidationRegistry.initialize, (address(identityProxy), deployer))
        );
        console.log("ValidationRegistry impl:", address(validationRegistryImpl));
        console.log("ValidationRegistry proxy:", address(validationRegistryProxy));

        // ── (e) ProviderRegistry (Daski) ──────────────────────────────
        ProviderRegistry registryImpl = new ProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                ProviderRegistry.initialize, (address(identityProxy), usdcAddress, treasury, listingFee, deployer)
            )
        );
        console.log("ProviderRegistry impl:", address(registryImpl));
        console.log("ProviderRegistry proxy:", address(registryProxy));

        // ── (f) PaymentRouter (Daski) ─────────────────────────────────
        PaymentRouter routerImpl = new PaymentRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PaymentRouter.initialize,
                (address(identityProxy), address(registryProxy), treasury, commissionBps, deployer)
            )
        );
        PaymentRouter router = PaymentRouter(address(routerProxy));
        console.log("PaymentRouter impl:", address(routerImpl));
        console.log("PaymentRouter proxy:", address(routerProxy));

        // ── (g) ReputationStorage (EAS resolver + refund sink) ────────
        ReputationStorage reputationImpl = new ReputationStorage();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(ReputationStorage.initialize, (address(identityProxy), address(routerProxy), deployer))
        );
        ReputationStorage reputation = ReputationStorage(address(reputationProxy));
        console.log("ReputationStorage impl:", address(reputationImpl));
        console.log("ReputationStorage proxy:", address(reputationProxy));

        // Register the two EAS schemas against this resolver. `revocable=true`
        // for confirmation (buyer can explicitly withdraw); `revocable=false`
        // for outcome (one-shot, immutable — the resolver would reject a
        // revoke anyway).
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
            abi.encodeCall(X402Adapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("X402Adapter impl:", address(x402AdapterImpl));
        console.log("X402Adapter proxy:", address(x402AdapterProxy));

        // ── (i) PermitAdapter ─────────────────────────────────────────
        PermitAdapter permitAdapterImpl = new PermitAdapter();
        ERC1967Proxy permitAdapterProxy = new ERC1967Proxy(
            address(permitAdapterImpl),
            abi.encodeCall(PermitAdapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("PermitAdapter impl:", address(permitAdapterImpl));
        console.log("PermitAdapter proxy:", address(permitAdapterProxy));

        // ── (j) ApprovalAdapter ───────────────────────────────────────
        ApprovalAdapter approvalAdapterImpl = new ApprovalAdapter();
        ERC1967Proxy approvalAdapterProxy = new ERC1967Proxy(
            address(approvalAdapterImpl),
            abi.encodeCall(ApprovalAdapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("ApprovalAdapter impl:", address(approvalAdapterImpl));
        console.log("ApprovalAdapter proxy:", address(approvalAdapterProxy));

        // ── (k) Wire whitelists ───────────────────────────────────────
        router.setAdapter(address(x402AdapterProxy), true);
        router.setAdapter(address(permitAdapterProxy), true);
        router.setAdapter(address(approvalAdapterProxy), true);
        router.setAcceptedToken(usdcAddress, true);
        router.setReputationStorage(address(reputationProxy));

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────
        console.log("-------------------------------------------");
        console.log("Deployment complete");
        console.log("  USDC:               ", usdcAddress);
        console.log("  IdentityRegistry:   ", address(identityProxy));
        console.log("  ReputationRegistry: ", address(reputationRegistryProxy));
        console.log("  ValidationRegistry: ", address(validationRegistryProxy));
        console.log("  ProviderRegistry:   ", address(registryProxy));
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
