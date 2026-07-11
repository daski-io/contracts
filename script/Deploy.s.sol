// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
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

/// @notice Deploy the full Daski stack including the new ServiceRegistry. On
///         Base Sepolia this also registers the two EAS schemas the new
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
        ProviderRegistry providerRegistryImpl = new ProviderRegistry();
        ERC1967Proxy providerRegistryProxy = new ERC1967Proxy(
            address(providerRegistryImpl),
            abi.encodeCall(
                ProviderRegistry.initialize, (address(identityProxy), usdcAddress, treasury, listingFee, deployer)
            )
        );
        console.log("ProviderRegistry impl:", address(providerRegistryImpl));
        console.log("ProviderRegistry proxy:", address(providerRegistryProxy));

        // ── (f) ServiceRegistry (Daski — new) ─────────────────────────
        ServiceRegistry serviceRegistryImpl = new ServiceRegistry();
        ERC1967Proxy serviceRegistryProxy = new ERC1967Proxy(
            address(serviceRegistryImpl),
            abi.encodeCall(
                ServiceRegistry.initialize, (address(identityProxy), address(providerRegistryProxy), deployer)
            )
        );
        console.log("ServiceRegistry impl:", address(serviceRegistryImpl));
        console.log("ServiceRegistry proxy:", address(serviceRegistryProxy));

        // ── (g) PaymentRouter (Daski) ─────────────────────────────────
        PaymentRouter routerImpl = new PaymentRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PaymentRouter.initialize,
                (
                    address(identityProxy),
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

        // ── (h) ReputationStorage (EAS resolver + refund sink) ────────
        ReputationStorage reputationImpl = new ReputationStorage();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(ReputationStorage.initialize, (address(identityProxy), address(routerProxy), deployer))
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

        // ── (i) X402Adapter ───────────────────────────────────────────
        X402Adapter x402AdapterImpl = new X402Adapter();
        ERC1967Proxy x402AdapterProxy = new ERC1967Proxy(
            address(x402AdapterImpl),
            abi.encodeCall(X402Adapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("X402Adapter impl:", address(x402AdapterImpl));
        console.log("X402Adapter proxy:", address(x402AdapterProxy));

        // ── (j) PermitAdapter ─────────────────────────────────────────
        PermitAdapter permitAdapterImpl = new PermitAdapter();
        ERC1967Proxy permitAdapterProxy = new ERC1967Proxy(
            address(permitAdapterImpl),
            abi.encodeCall(PermitAdapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("PermitAdapter impl:", address(permitAdapterImpl));
        console.log("PermitAdapter proxy:", address(permitAdapterProxy));

        // ── (k) ApprovalAdapter ───────────────────────────────────────
        ApprovalAdapter approvalAdapterImpl = new ApprovalAdapter();
        ERC1967Proxy approvalAdapterProxy = new ERC1967Proxy(
            address(approvalAdapterImpl),
            abi.encodeCall(ApprovalAdapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("ApprovalAdapter impl:", address(approvalAdapterImpl));
        console.log("ApprovalAdapter proxy:", address(approvalAdapterProxy));

        // ── (l) DirectTransferAdapter (external-facilitator rail) ─────
        // Attributes payments settled by an external x402 facilitator (CDP)
        // as bare EIP-3009 transfers into the router. ATTRIBUTOR_ADDRESS is
        // the gateway's facilitator wallet; when unset, ops must call
        // setAttributor before the external rail can settle anything.
        DirectTransferAdapter directAdapterImpl = new DirectTransferAdapter();
        ERC1967Proxy directAdapterProxy = new ERC1967Proxy(
            address(directAdapterImpl),
            abi.encodeCall(DirectTransferAdapter.initialize, (address(routerProxy), address(identityProxy), deployer))
        );
        console.log("DirectTransferAdapter impl:", address(directAdapterImpl));
        console.log("DirectTransferAdapter proxy:", address(directAdapterProxy));

        address attributor = vm.envOr("ATTRIBUTOR_ADDRESS", address(0));
        if (attributor != address(0)) {
            DirectTransferAdapter(address(directAdapterProxy)).setAttributor(attributor, true);
            console.log("Attributor whitelisted:", attributor);
        }

        // ── (m) Wire whitelists ───────────────────────────────────────
        router.setAdapter(address(x402AdapterProxy), true);
        router.setAdapter(address(permitAdapterProxy), true);
        router.setAdapter(address(approvalAdapterProxy), true);
        router.setAdapter(address(directAdapterProxy), true);
        router.setAcceptedToken(usdcAddress, true);
        router.setReputationStorage(address(reputationProxy));

        // ── (n) Admin handoff ─────────────────────────────────────────
        // All wiring above is onlyAdmin and ran as the deployer. If a separate
        // ADMIN_ADDRESS (multisig / timelock) was supplied, start the 2-step
        // transfer for every proxy now; the new admin completes it by calling
        // acceptAdmin() on each. Until then the deployer stays admin, so a
        // mistyped address is recoverable.
        if (finalAdmin != deployer) {
            address[11] memory adminContracts = [
                address(identityProxy),
                address(reputationRegistryProxy),
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
        console.log("  IdentityRegistry:   ", address(identityProxy));
        console.log("  ReputationRegistry: ", address(reputationRegistryProxy));
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
