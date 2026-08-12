// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";

/// @notice Validates a deployed splitter and writes the public manifest input.
contract WriteOutcomeSplitterManifest is Script {
    function run() external returns (string memory json) {
        OutcomeSplitter splitter = OutcomeSplitter(payable(vm.envAddress("STANDARD_RAIL_SPLITTER_ADDRESS")));
        address token = vm.envAddress("STANDARD_RAIL_CANONICAL_TOKEN");
        address provider = vm.envAddress("STANDARD_RAIL_PROVIDER_PAYEE");
        address daski = vm.envAddress("STANDARD_RAIL_DASKI_COMMISSION_RECEIVER");
        uint256 commissionBps = vm.envUint("STANDARD_RAIL_COMMISSION_BPS");
        bytes32 policyHash = vm.envBytes32("STANDARD_RAIL_POLICY_VERSION_HASH");
        bytes32 outcomeHash = vm.envBytes32("STANDARD_RAIL_OUTCOME_ID_HASH");
        bytes32 listingHash = vm.envBytes32("STANDARD_RAIL_LISTING_COMMITMENT_HASH");
        uint256 listingEpoch = vm.envUint("STANDARD_RAIL_LISTING_EPOCH");
        OutcomeSplitterFactory factory = OutcomeSplitterFactory(vm.envAddress("STANDARD_RAIL_SPLITTER_FACTORY"));
        bytes32 deploymentSalt = vm.envBytes32("STANDARD_RAIL_DEPLOYMENT_SALT");
        bytes32 deploymentTransaction = vm.envBytes32("STANDARD_RAIL_SPLITTER_DEPLOYMENT_TX");
        uint256 deploymentBlockNumber = vm.envUint("STANDARD_RAIL_SPLITTER_DEPLOYMENT_BLOCK_NUMBER");
        bytes32 deploymentBlockHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_DEPLOYMENT_BLOCK_HASH");

        require(splitter.canonicalChainId() == block.chainid, "chain mismatch");
        require(splitter.canonicalToken() == token, "token mismatch");
        require(splitter.providerPayee() == provider, "provider mismatch");
        require(splitter.daskiCommissionReceiver() == daski, "Daski receiver mismatch");
        require(splitter.commissionBps() == commissionBps, "commission mismatch");
        require(splitter.policyVersionHash() == policyHash, "policy mismatch");
        require(splitter.outcomeIdHash() == outcomeHash, "outcome mismatch");
        require(splitter.listingCommitmentHash() == listingHash, "listing mismatch");
        require(splitter.listingEpoch() == listingEpoch, "epoch mismatch");
        require(listingEpoch <= type(uint64).max, "epoch range");
        require(commissionBps <= type(uint16).max, "commission range");
        // Values are range checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps16 = uint16(commissionBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch64 = uint64(listingEpoch);
        require(
            factory.computeAddress(
                deploymentSalt,
                block.chainid,
                token,
                provider,
                daski,
                commissionBps16,
                policyHash,
                outcomeHash,
                listingHash,
                listingEpoch64
            ) == address(splitter),
            "factory provenance mismatch"
        );

        bytes32 creationCodeHash = keccak256(
            abi.encodePacked(
                type(OutcomeSplitter).creationCode,
                abi.encode(
                    block.chainid,
                    token,
                    provider,
                    daski,
                    commissionBps16,
                    policyHash,
                    outcomeHash,
                    listingHash,
                    listingEpoch64
                )
            )
        );

        bytes32 immutableHash = keccak256(
            abi.encode(
                block.chainid, token, provider, daski, commissionBps, policyHash, outcomeHash, listingHash, listingEpoch
            )
        );
        string memory object = "splitter";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "canonicalToken", token);
        vm.serializeAddress(object, "providerPayee", provider);
        vm.serializeAddress(object, "daskiCommissionReceiver", daski);
        vm.serializeUint(object, "commissionBps", commissionBps);
        vm.serializeBytes32(object, "policyVersionHash", policyHash);
        vm.serializeBytes32(object, "outcomeIdHash", outcomeHash);
        vm.serializeUint(object, "listingEpoch", listingEpoch);
        vm.serializeBytes32(object, "listingCommitmentHash", listingHash);
        vm.serializeAddress(object, "splitterAddress", address(splitter));
        vm.serializeAddress(object, "splitterFactory", address(factory));
        vm.serializeBytes32(object, "splitterDeploymentSalt", deploymentSalt);
        vm.serializeBytes32(object, "splitterCreationCodeHash", creationCodeHash);
        vm.serializeBytes32(object, "splitterDeploymentTransaction", deploymentTransaction);
        vm.serializeUint(object, "splitterDeploymentBlockNumber", deploymentBlockNumber);
        vm.serializeBytes32(object, "splitterDeploymentBlockHash", deploymentBlockHash);
        vm.serializeBytes32(object, "splitterRuntimeCodeHash", address(splitter).codehash);
        json = vm.serializeBytes32(object, "splitterImmutableHash", immutableHash);
        vm.writeJson(json, vm.envString("STANDARD_RAIL_MANIFEST_OUTPUT"));
    }
}
