// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";

/// @notice Validates a deployed splitter and writes the public manifest input.
contract WriteOutcomeSplitterManifest is Script {
    /// @dev Carried in memory instead of stack locals: with every input live
    /// in one frame, solc 0.8.24 + via_ir fails Yul codegen ("memPtr … too
    /// deep in the stack") during serialization.
    struct ManifestInput {
        OutcomeSplitter splitter;
        OutcomeSplitterFactory factory;
        address token;
        address provider;
        address daski;
        uint256 commissionBps;
        bytes32 policyHash;
        bytes32 outcomeHash;
        bytes32 listingHash;
        uint256 listingEpoch;
        bytes32 deploymentSalt;
        bytes32 deploymentTransaction;
        uint256 deploymentBlockNumber;
        bytes32 deploymentBlockHash;
    }

    function run() external returns (string memory json) {
        ManifestInput memory input = _readInput();
        _validate(input);
        json = _writeManifest(input);
    }

    function _readInput() internal view returns (ManifestInput memory input) {
        input.splitter = OutcomeSplitter(payable(vm.envAddress("STANDARD_RAIL_SPLITTER_ADDRESS")));
        input.factory = OutcomeSplitterFactory(vm.envAddress("STANDARD_RAIL_SPLITTER_FACTORY"));
        input.token = vm.envAddress("STANDARD_RAIL_CANONICAL_TOKEN");
        input.provider = vm.envAddress("STANDARD_RAIL_PROVIDER_PAYEE");
        input.daski = vm.envAddress("STANDARD_RAIL_DASKI_COMMISSION_RECEIVER");
        input.commissionBps = vm.envUint("STANDARD_RAIL_COMMISSION_BPS");
        input.policyHash = vm.envBytes32("STANDARD_RAIL_POLICY_VERSION_HASH");
        input.outcomeHash = vm.envBytes32("STANDARD_RAIL_OUTCOME_ID_HASH");
        input.listingHash = vm.envBytes32("STANDARD_RAIL_LISTING_COMMITMENT_HASH");
        input.listingEpoch = vm.envUint("STANDARD_RAIL_LISTING_EPOCH");
        input.deploymentSalt = vm.envBytes32("STANDARD_RAIL_DEPLOYMENT_SALT");
        input.deploymentTransaction = vm.envBytes32("STANDARD_RAIL_SPLITTER_DEPLOYMENT_TX");
        input.deploymentBlockNumber = vm.envUint("STANDARD_RAIL_SPLITTER_DEPLOYMENT_BLOCK_NUMBER");
        input.deploymentBlockHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_DEPLOYMENT_BLOCK_HASH");
    }

    function _validate(ManifestInput memory input) internal view {
        OutcomeSplitter splitter = input.splitter;
        require(splitter.canonicalChainId() == block.chainid, "chain mismatch");
        require(splitter.canonicalToken() == input.token, "token mismatch");
        require(splitter.providerPayee() == input.provider, "provider mismatch");
        require(splitter.daskiCommissionReceiver() == input.daski, "Daski receiver mismatch");
        require(splitter.commissionBps() == input.commissionBps, "commission mismatch");
        require(splitter.policyVersionHash() == input.policyHash, "policy mismatch");
        require(splitter.outcomeIdHash() == input.outcomeHash, "outcome mismatch");
        require(splitter.listingCommitmentHash() == input.listingHash, "listing mismatch");
        require(splitter.listingEpoch() == input.listingEpoch, "epoch mismatch");
        require(input.listingEpoch <= type(uint64).max, "epoch range");
        require(input.commissionBps <= type(uint16).max, "commission range");
        // Values are range checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps16 = uint16(input.commissionBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch64 = uint64(input.listingEpoch);
        require(
            input.factory
                .computeAddress(
                    input.deploymentSalt,
                    block.chainid,
                    input.token,
                    input.provider,
                    input.daski,
                    commissionBps16,
                    input.policyHash,
                    input.outcomeHash,
                    input.listingHash,
                    listingEpoch64
                ) == address(splitter),
            "factory provenance mismatch"
        );
    }

    function _creationCodeHash(ManifestInput memory input) internal view returns (bytes32) {
        require(input.commissionBps <= type(uint16).max, "commission range");
        require(input.listingEpoch <= type(uint64).max, "epoch range");
        // Values are range checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps16 = uint16(input.commissionBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch64 = uint64(input.listingEpoch);
        return keccak256(
            abi.encodePacked(
                type(OutcomeSplitter).creationCode,
                abi.encode(
                    block.chainid,
                    input.token,
                    input.provider,
                    input.daski,
                    commissionBps16,
                    input.policyHash,
                    input.outcomeHash,
                    input.listingHash,
                    listingEpoch64
                )
            )
        );
    }

    function _immutableHash(ManifestInput memory input) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                input.token,
                input.provider,
                input.daski,
                input.commissionBps,
                input.policyHash,
                input.outcomeHash,
                input.listingHash,
                input.listingEpoch
            )
        );
    }

    function _writeManifest(ManifestInput memory input) internal returns (string memory json) {
        string memory object = "splitter";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "canonicalToken", input.token);
        vm.serializeAddress(object, "providerPayee", input.provider);
        vm.serializeAddress(object, "daskiCommissionReceiver", input.daski);
        vm.serializeUint(object, "commissionBps", input.commissionBps);
        vm.serializeBytes32(object, "policyVersionHash", input.policyHash);
        vm.serializeBytes32(object, "outcomeIdHash", input.outcomeHash);
        vm.serializeUint(object, "listingEpoch", input.listingEpoch);
        vm.serializeBytes32(object, "listingCommitmentHash", input.listingHash);
        vm.serializeAddress(object, "splitterAddress", address(input.splitter));
        vm.serializeAddress(object, "splitterFactory", address(input.factory));
        vm.serializeBytes32(object, "splitterDeploymentSalt", input.deploymentSalt);
        vm.serializeBytes32(object, "splitterCreationCodeHash", _creationCodeHash(input));
        vm.serializeBytes32(object, "splitterDeploymentTransaction", input.deploymentTransaction);
        vm.serializeUint(object, "splitterDeploymentBlockNumber", input.deploymentBlockNumber);
        vm.serializeBytes32(object, "splitterDeploymentBlockHash", input.deploymentBlockHash);
        vm.serializeBytes32(object, "splitterRuntimeCodeHash", address(input.splitter).codehash);
        json = vm.serializeBytes32(object, "splitterImmutableHash", _immutableHash(input));
        vm.writeJson(json, vm.envString("STANDARD_RAIL_MANIFEST_OUTPUT"));
    }
}
