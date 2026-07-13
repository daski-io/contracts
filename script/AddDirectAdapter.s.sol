// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DirectTransferAdapter} from "../src/adapters/DirectTransferAdapter.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";

/// @notice Targeted deploy: add DirectTransferAdapter (the external-
///         facilitator / x402 Bazaar rail) to an ALREADY-DEPLOYED Daski
///         stack. Use this instead of Deploy.s.sol, which deploys a whole
///         fresh stack and would orphan the running one.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY       broadcaster (pays gas; becomes adapter admin)
///   PAYMENT_ROUTER_ADDRESS     existing PaymentRouter proxy
///   AGENT_INDEX_ADDRESS        existing AgentIndex proxy (the adapter
///                              resolves buyer wallets through it — NOT the
///                              canonical identity registry, which has no
///                              reverse lookup)
/// Optional env:
///   ATTRIBUTOR_ADDRESS  gateway facilitator wallet to whitelist for
///                       attribute(). Without it the rail cannot settle —
///                       set it here or call setAttributor later.
///   ADMIN_ADDRESS       final admin (multisig/timelock). When set and
///                       different from the deployer, a 2-step transferAdmin
///                       is started; the new admin must call acceptAdmin().
///
/// Router wiring: if the deployer is the router's current admin (testnet
/// convention), the script registers the adapter via setAdapter directly.
/// Otherwise it logs the exact call for the real admin to execute.
contract AddDirectAdapter is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address routerAddress = vm.envAddress("PAYMENT_ROUTER_ADDRESS");
        address agentIndexAddress = vm.envAddress("AGENT_INDEX_ADDRESS");
        address attributor = vm.envOr("ATTRIBUTOR_ADDRESS", address(0));
        address deployer = vm.addr(deployerKey);
        address finalAdmin = vm.envOr("ADMIN_ADDRESS", deployer);

        console.log("Deployer:     ", deployer);
        console.log("PaymentRouter:", routerAddress);
        console.log("AgentIndex:   ", agentIndexAddress);

        vm.startBroadcast(deployerKey);

        DirectTransferAdapter impl = new DirectTransferAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DirectTransferAdapter.initialize, (routerAddress, agentIndexAddress, deployer))
        );
        DirectTransferAdapter adapter = DirectTransferAdapter(address(proxy));
        console.log("DirectTransferAdapter impl: ", address(impl));
        console.log("DirectTransferAdapter proxy:", address(proxy));

        if (attributor != address(0)) {
            adapter.setAttributor(attributor, true);
            console.log("Attributor whitelisted:", attributor);
        } else {
            console.log("NOTE: no ATTRIBUTOR_ADDRESS set. Before the rail can");
            console.log("settle, the admin must call:");
            console.log("  DirectTransferAdapter.setAttributor(<gateway facilitator wallet>, true)");
        }

        PaymentRouter router = PaymentRouter(routerAddress);
        if (router.admin() == deployer) {
            router.setAdapter(address(proxy), true);
            console.log("Router adapter whitelisted.");
        } else {
            console.log("Deployer is NOT the router admin. The router admin must call:");
            console.log("  PaymentRouter.setAdapter(<adapter proxy>, true)");
        }

        if (finalAdmin != deployer) {
            adapter.transferAdmin(finalAdmin);
            console.log("Adapter admin transfer started to:", finalAdmin);
            console.log("  new admin MUST call acceptAdmin() to complete handover");
        }

        vm.stopBroadcast();

        console.log("-------------------------------------------");
        console.log("Next steps (gateway):");
        console.log("  1. Set DIRECT_ADAPTER_ADDRESS to the proxy address above");
        console.log("     (Railway: railway variables --service gateway --skip-deploys \\");
        console.log("        --set DIRECT_ADAPTER_ADDRESS=<proxy> && railway redeploy)");
        console.log("  2. Record the proxy in deployments/<network>.json + README table");
        console.log("-------------------------------------------");
    }
}
