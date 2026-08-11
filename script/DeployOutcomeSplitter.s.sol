// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";

/// @notice Deploys the permissionless factory and one reviewed outcome splitter.
contract DeployOutcomeSplitter is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (OutcomeSplitterFactory factory, address splitter) {
        address provider = vm.envAddress("GATE1_PROVIDER_RECIPIENT");
        address daski = vm.envAddress("GATE1_DASKI_RECIPIENT");
        uint256 commissionBpsRaw = vm.envUint("GATE1_COMMISSION_BPS");
        bytes32 policyHash = vm.envBytes32("GATE1_POLICY_VERSION_HASH");
        bytes32 outcomeHash = vm.envBytes32("GATE1_OUTCOME_ID_HASH");
        bytes32 listingHash = vm.envBytes32("GATE1_LISTING_COMMITMENT_HASH");
        uint256 listingEpochRaw = vm.envUint("GATE1_LISTING_EPOCH");
        bytes32 salt = vm.envBytes32("GATE1_DEPLOYMENT_SALT");

        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "Gate 1 is Base Sepolia only");
        require(commissionBpsRaw > 0 && commissionBpsRaw < 10_000, "invalid commission bps");
        require(listingEpochRaw > 0 && listingEpochRaw <= type(uint64).max, "invalid listing epoch");
        // Both values are range-checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps = uint16(commissionBpsRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch = uint64(listingEpochRaw);

        vm.startBroadcast();
        factory = new OutcomeSplitterFactory();
        splitter = factory.deploy(
            salt,
            BASE_SEPOLIA_CHAIN_ID,
            BASE_SEPOLIA_USDC,
            provider,
            daski,
            commissionBps,
            policyHash,
            outcomeHash,
            listingHash,
            listingEpoch
        );
        vm.stopBroadcast();

        require(
            factory.computeAddress(
                salt,
                BASE_SEPOLIA_CHAIN_ID,
                BASE_SEPOLIA_USDC,
                provider,
                daski,
                commissionBps,
                policyHash,
                outcomeHash,
                listingHash,
                listingEpoch
            ) == splitter,
            "splitter address mismatch"
        );
    }
}
