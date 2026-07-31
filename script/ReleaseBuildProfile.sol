// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";

/// @notice Pinned build and declarative manifest fields for audited releases.
abstract contract ReleaseBuildProfile is Script {
    string internal constant SOLC_VERSION = "0.8.24+commit.e11b9ed9";
    string internal constant EVM_VERSION = "cancun";
    string internal constant FOUNDRY_VERSION = "1.5.1-stable";
    string internal constant FOUNDRY_COMMIT = "b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2";

    function _validateBuildProfile(string memory json, string memory sourceCommit) internal pure {
        _validateSourceCommit(sourceCommit);
        require(vm.parseJsonBytes32(json, ".build.sourceClosureHash") != bytes32(0), "zero source closure hash");
        require(vm.parseJsonBytes32(json, ".build.compilerInputHash") != bytes32(0), "zero compiler input hash");
        require(vm.parseJsonBytes32(json, ".build.foundryConfigHash") != bytes32(0), "zero Foundry config hash");
        require(
            keccak256(bytes(vm.parseJsonString(json, ".build.solcVersion"))) == keccak256(bytes(SOLC_VERSION)),
            "wrong manifest solc version"
        );
        require(vm.parseJsonBool(json, ".build.optimizer"), "optimizer must be enabled");
        require(vm.parseJsonUint(json, ".build.optimizerRuns") == 200, "wrong optimizer runs");
        require(vm.parseJsonBool(json, ".build.viaIr"), "via-ir must be enabled");
        require(
            keccak256(bytes(vm.parseJsonString(json, ".build.evmVersion"))) == keccak256(bytes(EVM_VERSION)),
            "wrong manifest EVM version"
        );
        require(
            keccak256(bytes(vm.parseJsonString(json, ".build.foundryVersion"))) == keccak256(bytes(FOUNDRY_VERSION)),
            "wrong manifest Foundry version"
        );
        require(
            keccak256(bytes(vm.parseJsonString(json, ".build.foundryCommit"))) == keccak256(bytes(FOUNDRY_COMMIT)),
            "wrong manifest Foundry commit"
        );
    }

    function _validateSourceCommit(string memory sourceCommit) internal pure {
        bytes memory value = bytes(sourceCommit);
        require(value.length == 40, "invalid source commit");
        bool nonzero;
        for (uint256 i = 0; i < value.length; i++) {
            bytes1 char = value[i];
            require((char >= "0" && char <= "9") || (char >= "a" && char <= "f"), "invalid source commit");
            if (char != "0") nonzero = true;
        }
        require(nonzero, "zero source commit");
    }

    function _validateSchemaDefinitions(string memory outcome, string memory confirmation) internal pure {
        require(
            keccak256(bytes(outcome)) == keccak256(bytes(DeploymentValidation.outcomeSchema())),
            "wrong manifest outcome schema"
        );
        require(
            keccak256(bytes(confirmation)) == keccak256(bytes(DeploymentValidation.confirmationSchema())),
            "wrong manifest confirmation schema"
        );
    }
}
