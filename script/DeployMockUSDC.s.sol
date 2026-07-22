// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Deploys the unrestricted-mint USDC test double on non-mainnet chains.
contract DeployMockUSDC is Script {
    function run() external returns (MockUSDC token) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        token = new MockUSDC();
        vm.stopBroadcast();

        console.log("Test-only MockUSDC:", address(token));
        console.log("Set USDC_ADDRESS to this address before running Deploy.s.sol");
    }
}
