// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockSanctionsList} from "../test/mocks/MockSanctionsList.sol";

/// @notice Deploys a controllable sanctions test double on non-mainnet chains.
contract DeployMockSanctionsList is Script {
    function run() external returns (MockSanctionsList oracle) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        oracle = new MockSanctionsList();
        vm.stopBroadcast();

        console.log("Test-only MockSanctionsList:", address(oracle));
        console.log("Set SANCTIONS_ORACLE_ADDRESS and ALLOW_MOCK_SANCTIONS_ORACLE=true before deployment");
    }
}
