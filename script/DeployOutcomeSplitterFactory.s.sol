// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterScriptBase} from "./OutcomeSplitterScriptBase.sol";

/// @notice Deploys the one permissionless factory used by all standard-rail outcomes.
contract DeployOutcomeSplitterFactory is OutcomeSplitterScriptBase {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;

    function run() external returns (OutcomeSplitterFactory factory) {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "standard Testnet rail is Base Sepolia only");
        bytes32 reviewedHash = _reviewedFactoryRuntimeCodeHash();
        vm.startBroadcast();
        factory = new OutcomeSplitterFactory();
        vm.stopBroadcast();
        _validateReviewedFactory(address(factory), reviewedHash);
    }
}
