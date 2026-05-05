// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";

/// @notice One-shot upgrade script for the gasless-registration change.
/// Deploys new impls of IdentityRegistry + X402Adapter and points the
/// existing UUPS proxies at them. Storage layout is preserved (the only
/// new state is `_registrationNonces` appended at the end of
/// IdentityRegistry).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY      — must be the admin of both proxies
///   IDENTITY_REGISTRY_ADDRESS — proxy address (from gateway env)
///   X402_ADAPTER_ADDRESS      — proxy address (from gateway env)
contract UpgradeRegistration is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address identityProxy = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        address x402Proxy = vm.envAddress("X402_ADAPTER_ADDRESS");

        address deployer = vm.addr(deployerKey);
        console.log("Upgrader (must be admin):", deployer);
        console.log("IdentityRegistry proxy:  ", identityProxy);
        console.log("X402Adapter proxy:       ", x402Proxy);

        vm.startBroadcast(deployerKey);

        IdentityRegistry newIdentityImpl = new IdentityRegistry();
        IdentityRegistry(identityProxy).upgradeToAndCall(address(newIdentityImpl), "");
        console.log("IdentityRegistry new impl:", address(newIdentityImpl));

        X402Adapter newX402Impl = new X402Adapter();
        X402Adapter(x402Proxy).upgradeToAndCall(address(newX402Impl), "");
        console.log("X402Adapter new impl:     ", address(newX402Impl));

        vm.stopBroadcast();
    }
}
