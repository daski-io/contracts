// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterScriptBase} from "./OutcomeSplitterScriptBase.sol";
import {StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";

/// @notice Deploys one reviewed outcome splitter through the shared factory,
///         bound to the executing chain and that chain's reviewed Circle USDC.
contract DeployOutcomeSplitter is OutcomeSplitterScriptBase {
    /// @dev Carried in memory instead of stack locals so the script also
    ///      compiles without the IR pipeline, as coverage builds do.
    struct SplitterInput {
        OutcomeSplitterFactory factory;
        address provider;
        address daski;
        uint256 commissionBps;
        bytes32 policyHash;
        bytes32 outcomeHash;
        bytes32 listingHash;
        uint256 listingEpoch;
        bytes32 salt;
        bytes32 factoryRuntimeCodeHash;
        bytes32 creationCodeHash;
        bytes32 initCodeHash;
    }

    function run() external returns (address splitter) {
        splitter = _deploy(_readInput());
    }

    function _readInput() internal view returns (SplitterInput memory input) {
        input.factory = OutcomeSplitterFactory(vm.envAddress("STANDARD_RAIL_SPLITTER_FACTORY"));
        input.provider = vm.envAddress("STANDARD_RAIL_PROVIDER_PAYEE");
        input.daski = vm.envAddress("STANDARD_RAIL_DASKI_COMMISSION_RECEIVER");
        input.commissionBps = vm.envOr("MARKETPLACE_COMMISSION_BPS", uint256(500));
        input.policyHash = vm.envBytes32("STANDARD_RAIL_POLICY_VERSION_HASH");
        input.outcomeHash = vm.envBytes32("STANDARD_RAIL_OUTCOME_ID_HASH");
        input.listingHash = vm.envBytes32("STANDARD_RAIL_LISTING_COMMITMENT_HASH");
        input.listingEpoch = vm.envUint("STANDARD_RAIL_LISTING_EPOCH");
        input.salt = vm.envBytes32("STANDARD_RAIL_DEPLOYMENT_SALT");
        input.factoryRuntimeCodeHash = _reviewedFactoryRuntimeCodeHash();
        input.creationCodeHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_CREATION_CODE_HASH");
        input.initCodeHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_INIT_CODE_HASH");
    }

    function _deploy(SplitterInput memory input) internal returns (address splitter) {
        address canonicalToken = StandardRailCircleUSDC.canonicalToken(block.chainid);
        require(input.commissionBps > 0 && input.commissionBps < 10_000, "invalid commission bps");
        require(input.listingEpoch > 0 && input.listingEpoch <= type(uint64).max, "invalid listing epoch");
        // Both values are range-checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps = uint16(input.commissionBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch = uint64(input.listingEpoch);

        _validateReviewedFactory(address(input.factory), input.factoryRuntimeCodeHash);
        require(
            OutcomeSplitterCreate2.creationCodeHash() == input.creationCodeHash, "splitter creation code hash mismatch"
        );
        bytes32 localInitCodeHash = _initCodeHash(input, canonicalToken, commissionBps, listingEpoch);
        require(localInitCodeHash == input.initCodeHash, "splitter init code hash mismatch");
        address predicted = OutcomeSplitterCreate2.computeAddress(address(input.factory), input.salt, localInitCodeHash);

        vm.startBroadcast();
        splitter = _deployThroughFactory(input, canonicalToken, commissionBps, listingEpoch);
        vm.stopBroadcast();

        require(splitter == predicted, "splitter address mismatch");
        require(splitter.code.length != 0, "splitter deployment missing code");
    }

    function _initCodeHash(
        SplitterInput memory input,
        address canonicalToken,
        uint16 commissionBps,
        uint64 listingEpoch
    ) private view returns (bytes32) {
        return OutcomeSplitterCreate2.initCodeHash(
            block.chainid,
            canonicalToken,
            input.provider,
            input.daski,
            commissionBps,
            input.policyHash,
            input.outcomeHash,
            input.listingHash,
            listingEpoch
        );
    }

    function _deployThroughFactory(
        SplitterInput memory input,
        address canonicalToken,
        uint16 commissionBps,
        uint64 listingEpoch
    ) private returns (address) {
        return input.factory
            .deploy(
                input.salt,
                block.chainid,
                canonicalToken,
                input.provider,
                input.daski,
                commissionBps,
                input.policyHash,
                input.outcomeHash,
                input.listingHash,
                listingEpoch
            );
    }
}
