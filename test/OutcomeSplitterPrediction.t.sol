// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterValidation} from "../src/utils/OutcomeSplitterValidation.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract OutcomeSplitterValidationHarness {
    function validate(
        uint256 chainId,
        address token,
        address provider,
        address daski,
        uint16 commissionBps,
        bytes32 policyHash,
        bytes32 outcomeHash,
        bytes32 listingHash,
        uint64 listingEpoch,
        address splitter
    ) external view {
        OutcomeSplitterValidation.validate(
            chainId, token, provider, daski, commissionBps, policyHash, outcomeHash, listingHash, listingEpoch, splitter
        );
    }
}

contract OutcomeSplitterPredictionTest is Test {
    struct Config {
        uint256 chainId;
        address token;
        address provider;
        address daski;
        uint16 commissionBps;
        bytes32 policyHash;
        bytes32 outcomeHash;
        bytes32 listingHash;
        uint64 listingEpoch;
    }

    MockUSDC private token;
    OutcomeSplitterFactory private factory;
    OutcomeSplitterValidationHarness private validationHarness;
    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");

    function setUp() public {
        vm.chainId(84_532);
        token = new MockUSDC();
        factory = new OutcomeSplitterFactory();
        validationHarness = new OutcomeSplitterValidationHarness();
    }

    function testPredictionRejectsInvalidChainAndToken() public {
        Config memory config = _validConfig();
        config.chainId++;
        vm.expectRevert(OutcomeSplitter.InvalidChain.selector);
        _compute(config);

        config = _validConfig();
        config.token = address(0);
        vm.expectRevert(OutcomeSplitter.InvalidToken.selector);
        _compute(config);

        config.token = makeAddr("code-less-token");
        vm.expectRevert(OutcomeSplitter.InvalidToken.selector);
        _compute(config);
    }

    function testPredictionRejectsInvalidRecipients() public {
        Config memory config = _validConfig();
        config.provider = address(0);
        _expectInvalidRecipient(config);
        config = _validConfig();
        config.daski = address(0);
        _expectInvalidRecipient(config);
        config = _validConfig();
        config.daski = config.provider;
        _expectInvalidRecipient(config);
        config = _validConfig();
        config.provider = config.token;
        _expectInvalidRecipient(config);
        config = _validConfig();
        config.daski = config.token;
        _expectInvalidRecipient(config);
    }

    function testPredictionRejectsInvalidCommissionAndListing() public {
        Config memory config = _validConfig();
        config.commissionBps = 0;
        vm.expectRevert(OutcomeSplitter.InvalidCommission.selector);
        _compute(config);
        config.commissionBps = 10_000;
        vm.expectRevert(OutcomeSplitter.InvalidCommission.selector);
        _compute(config);

        config = _validConfig();
        config.policyHash = bytes32(0);
        _expectInvalidListing(config);
        config = _validConfig();
        config.outcomeHash = bytes32(0);
        _expectInvalidListing(config);
        config = _validConfig();
        config.listingHash = bytes32(0);
        _expectInvalidListing(config);
        config = _validConfig();
        config.listingEpoch = 0;
        _expectInvalidListing(config);
    }

    function testArbitraryServiceScopedListingKeysRemainIndependent() public view {
        uint256 agentA = 42;
        uint256 agentB = 77;
        bytes32 serviceA = keccak256(abi.encode(agentA, "orbital-logistics", "1"));
        bytes32 serviceB = keccak256(abi.encode(agentB, "orbital-logistics", "1"));
        bytes32 listingKeyA =
            keccak256(abi.encode("DaskiListingKeyV1", block.chainid, agentA, serviceA, "reserve-orbit"));
        bytes32 listingKeyB =
            keccak256(abi.encode("DaskiListingKeyV1", block.chainid, agentB, serviceB, "reserve-orbit"));

        assertTrue(listingKeyA != listingKeyB);

        Config memory configA = _validConfig();
        configA.outcomeHash = listingKeyA;
        Config memory configB = _validConfig();
        configB.outcomeHash = listingKeyB;
        assertTrue(_compute(configA) != _compute(configB));
    }

    function testServiceVersionChangesListingKeyAndPredictedSplitter() public view {
        uint256 agentId = 42;
        bytes32 serviceV1 = keccak256(abi.encode(agentId, "orbital-logistics", "1"));
        bytes32 serviceV2 = keccak256(abi.encode(agentId, "orbital-logistics", "2"));
        bytes32 listingKeyV1 =
            keccak256(abi.encode("DaskiListingKeyV1", block.chainid, agentId, serviceV1, "reserve-orbit"));
        bytes32 listingKeyV2 =
            keccak256(abi.encode("DaskiListingKeyV1", block.chainid, agentId, serviceV2, "reserve-orbit"));

        assertTrue(serviceV1 != serviceV2);
        assertTrue(listingKeyV1 != listingKeyV2);

        Config memory configV1 = _validConfig();
        configV1.outcomeHash = listingKeyV1;
        Config memory configV2 = _validConfig();
        configV2.outcomeHash = listingKeyV2;
        assertTrue(_compute(configV1) != _compute(configV2));
    }

    function testSharedValidationRejectsSplitterRecipients() public {
        Config memory config = _validConfig();
        address predicted = makeAddr("predicted-splitter");
        config.provider = predicted;
        vm.expectRevert(OutcomeSplitter.InvalidRecipient.selector);
        _validate(config, predicted);

        config = _validConfig();
        config.daski = predicted;
        vm.expectRevert(OutcomeSplitter.InvalidRecipient.selector);
        _validate(config, predicted);
    }

    function _validConfig() private view returns (Config memory config) {
        config = Config({
            chainId: block.chainid,
            token: address(token),
            provider: provider,
            daski: daski,
            commissionBps: 500,
            policyHash: keccak256("policy"),
            outcomeHash: keccak256("outcome"),
            listingHash: keccak256("listing"),
            listingEpoch: 1
        });
    }

    function _compute(Config memory config) private view returns (address) {
        return factory.computeAddress(
            keccak256("salt"),
            config.chainId,
            config.token,
            config.provider,
            config.daski,
            config.commissionBps,
            config.policyHash,
            config.outcomeHash,
            config.listingHash,
            config.listingEpoch
        );
    }

    function _validate(Config memory config, address splitter) private view {
        validationHarness.validate(
            config.chainId,
            config.token,
            config.provider,
            config.daski,
            config.commissionBps,
            config.policyHash,
            config.outcomeHash,
            config.listingHash,
            config.listingEpoch,
            splitter
        );
    }

    function _expectInvalidRecipient(Config memory config) private {
        vm.expectRevert(OutcomeSplitter.InvalidRecipient.selector);
        _compute(config);
    }

    function _expectInvalidListing(Config memory config) private {
        vm.expectRevert(OutcomeSplitter.InvalidListing.selector);
        _compute(config);
    }
}
