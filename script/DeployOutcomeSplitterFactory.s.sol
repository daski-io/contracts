// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterScriptBase} from "./OutcomeSplitterScriptBase.sol";
import {StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";

/// @notice Deploys the one permissionless factory used by all standard-rail outcomes.
contract DeployOutcomeSplitterFactory is OutcomeSplitterScriptBase {
    function run() external returns (OutcomeSplitterFactory factory) {
        StandardRailCircleUSDC.requireSupportedChain(block.chainid);
        bytes32 reviewedHash = _reviewedFactoryRuntimeCodeHash();
        vm.startBroadcast();
        factory = new OutcomeSplitterFactory();
        vm.stopBroadcast();
        _validateReviewedFactory(address(factory), reviewedHash);
    }
}
