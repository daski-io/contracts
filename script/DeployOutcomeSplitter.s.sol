// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterScriptBase} from "./OutcomeSplitterScriptBase.sol";
import {StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";

/// @notice Deploys one reviewed outcome splitter through the shared factory.
contract DeployOutcomeSplitter is OutcomeSplitterScriptBase {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (address splitter) {
        OutcomeSplitterFactory factory = OutcomeSplitterFactory(vm.envAddress("STANDARD_RAIL_SPLITTER_FACTORY"));
        address provider = vm.envAddress("STANDARD_RAIL_PROVIDER_PAYEE");
        address daski = vm.envAddress("STANDARD_RAIL_DASKI_COMMISSION_RECEIVER");
        uint256 commissionBpsRaw = vm.envOr("MARKETPLACE_COMMISSION_BPS", uint256(500));
        bytes32 policyHash = vm.envBytes32("STANDARD_RAIL_POLICY_VERSION_HASH");
        bytes32 outcomeHash = vm.envBytes32("STANDARD_RAIL_OUTCOME_ID_HASH");
        bytes32 listingHash = vm.envBytes32("STANDARD_RAIL_LISTING_COMMITMENT_HASH");
        uint256 listingEpochRaw = vm.envUint("STANDARD_RAIL_LISTING_EPOCH");
        bytes32 salt = vm.envBytes32("STANDARD_RAIL_DEPLOYMENT_SALT");
        bytes32 reviewedFactoryHash = _reviewedFactoryRuntimeCodeHash();
        bytes32 reviewedCreationCodeHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_CREATION_CODE_HASH");
        bytes32 reviewedInitCodeHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_INIT_CODE_HASH");

        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "standard Testnet rail is Base Sepolia only");
        require(commissionBpsRaw > 0 && commissionBpsRaw < 10_000, "invalid commission bps");
        require(listingEpochRaw > 0 && listingEpochRaw <= type(uint64).max, "invalid listing epoch");
        // Both values are range-checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps = uint16(commissionBpsRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch = uint64(listingEpochRaw);

        _validateReviewedFactory(address(factory), reviewedFactoryHash);
        require(
            OutcomeSplitterCreate2.creationCodeHash() == reviewedCreationCodeHash,
            "splitter creation code hash mismatch"
        );
        bytes32 localInitCodeHash = OutcomeSplitterCreate2.initCodeHash(
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
        require(localInitCodeHash == reviewedInitCodeHash, "splitter init code hash mismatch");
        address predicted = OutcomeSplitterCreate2.computeAddress(address(factory), salt, localInitCodeHash);
        // This head-state check avoids a knowingly unusable broadcast. The manifest
        // script is the sole activation gate and validates the finalized checkpoint.
        StandardRailCircleUSDC.validate(BASE_SEPOLIA_USDC, predicted, provider, daski);

        vm.startBroadcast();
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

        require(splitter == predicted, "splitter address mismatch");
        require(splitter.code.length != 0, "splitter deployment missing code");
    }
}
