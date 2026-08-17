// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";

/// @notice Shared reviewed-bytecode checks for outcome splitter deployment tooling.
abstract contract OutcomeSplitterScriptBase is Script {
    string internal constant FACTORY_RUNTIME_CODE_HASH_ENV = "STANDARD_RAIL_SPLITTER_FACTORY_RUNTIME_CODE_HASH";

    function compiledFactoryRuntimeCodeHash() public pure returns (bytes32) {
        return keccak256(type(OutcomeSplitterFactory).runtimeCode);
    }

    function _reviewedFactoryRuntimeCodeHash() internal view returns (bytes32 reviewedHash) {
        reviewedHash = vm.envBytes32(FACTORY_RUNTIME_CODE_HASH_ENV);
        require(reviewedHash == compiledFactoryRuntimeCodeHash(), "reviewed factory hash does not match build");
    }

    function _validateReviewedFactory(address factory, bytes32 reviewedHash) internal view {
        require(reviewedHash == compiledFactoryRuntimeCodeHash(), "reviewed factory hash does not match build");
        require(factory.codehash == reviewedHash, "factory runtime code hash mismatch");
    }
}
