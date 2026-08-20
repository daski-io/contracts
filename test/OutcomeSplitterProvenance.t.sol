// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterScriptBase} from "../script/OutcomeSplitterScriptBase.sol";
import {WriteOutcomeSplitterManifest} from "../script/WriteOutcomeSplitterManifest.s.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract OutcomeSplitterProvenanceHarness is OutcomeSplitterScriptBase {
    function validateFactory(address factory, bytes32 reviewedHash) external view {
        _validateReviewedFactory(factory, reviewedHash);
    }
}

contract OutcomeSplitterManifestHarness is WriteOutcomeSplitterManifest {
    function validate(ManifestInput memory input) external view {
        _validate(input);
    }

    function rpcBlockTag(uint256 blockNumber) external pure returns (string memory) {
        return _rpcBlockTag(blockNumber);
    }

    function deploymentPositionFromReceipt(string memory receipt, ManifestInput memory input)
        external
        pure
        returns (uint256 transactionIndex, uint256 logIndex)
    {
        return _deploymentPositionFromReceipt(receipt, input);
    }

    function writeManifest(ManifestInput memory input) external returns (string memory) {
        return _writeManifest(input);
    }
}

contract SelfConsistentFactory {
    address private immutable _ADVERTISED_SPLITTER;

    constructor(address advertisedSplitter_) {
        _ADVERTISED_SPLITTER = advertisedSplitter_;
    }

    function deploy(bytes32, uint256, address, address, address, uint16, bytes32, bytes32, bytes32, uint64)
        external
        view
        returns (address)
    {
        return _ADVERTISED_SPLITTER;
    }

    function computeAddress(bytes32, uint256, address, address, address, uint16, bytes32, bytes32, bytes32, uint64)
        external
        view
        returns (address)
    {
        return _ADVERTISED_SPLITTER;
    }
}

contract OutcomeSplitterProvenanceTest is Test {
    MockUSDC private token;
    OutcomeSplitterFactory private factory;
    OutcomeSplitterProvenanceHarness private provenanceHarness;
    OutcomeSplitterManifestHarness private manifestHarness;

    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");
    bytes32 private policyHash = keccak256("policy");
    bytes32 private outcomeHash = keccak256("outcome");
    bytes32 private listingHash = keccak256("listing");
    bytes32 private salt = keccak256("salt");

    function setUp() public {
        vm.chainId(84532);
        vm.roll(100);
        token = new MockUSDC();
        factory = new OutcomeSplitterFactory();
        provenanceHarness = new OutcomeSplitterProvenanceHarness();
        manifestHarness = new OutcomeSplitterManifestHarness();
    }

    function testLocalHashesAndCreate2MatchFactoryDeployment() public {
        bytes32 creationCodeHash = OutcomeSplitterCreate2.creationCodeHash();
        bytes32 initCodeHash = _initCodeHash();
        address predicted = OutcomeSplitterCreate2.computeAddress(address(factory), salt, initCodeHash);

        assertEq(creationCodeHash, keccak256(type(OutcomeSplitter).creationCode));
        assertEq(factory.splitterCreationCodeHash(), creationCodeHash);
        assertEq(
            factory.initCodeHash(
                block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
            ),
            initCodeHash
        );
        assertEq(
            factory.computeAddress(
                salt, block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
            ),
            predicted
        );
        assertEq(_deploy(), predicted);
    }

    function testSelfConsistentFactoryCannotSatisfyReviewedProvenance() public {
        OutcomeSplitter advertised = new OutcomeSplitter(
            block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );
        SelfConsistentFactory spoof = new SelfConsistentFactory(address(advertised));

        address claimed = spoof.computeAddress(
            salt, block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );
        assertEq(
            spoof.deploy(
                salt, block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
            ),
            claimed
        );
        assertNotEq(OutcomeSplitterCreate2.computeAddress(address(spoof), salt, _initCodeHash()), claimed);

        bytes32 reviewedHash = provenanceHarness.compiledFactoryRuntimeCodeHash();
        vm.expectRevert(bytes("factory runtime code hash mismatch"));
        provenanceHarness.validateFactory(address(spoof), reviewedHash);

        vm.expectRevert(bytes("reviewed factory hash does not match build"));
        provenanceHarness.validateFactory(address(spoof), address(spoof).codehash);
    }

    function testManifestValidatesLocalHashesAndCreate2() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        manifestHarness.validate(input);

        input.initCodeHash = bytes32(uint256(input.initCodeHash) ^ 1);
        vm.expectRevert(bytes("splitter init code hash mismatch"));
        manifestHarness.validate(input);

        input = _manifestInput(splitter);
        input.creationCodeHash = bytes32(uint256(input.creationCodeHash) ^ 1);
        vm.expectRevert(bytes("splitter creation code hash mismatch"));
        manifestHarness.validate(input);
    }

    function testManifestRejectsInvalidActivationMetadata() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);

        input.activationPosition = "AFTER_TRANSACTION";
        vm.expectRevert(bytes("activation position mismatch"));
        manifestHarness.validate(input);

        input = _manifestInput(splitter);
        input.activationBlockHash = bytes32(0);
        vm.expectRevert(bytes("zero activation block hash"));
        manifestHarness.validate(input);

        input = _manifestInput(splitter);
        input.activationBlockNumber = input.deploymentBlockNumber - 1;
        vm.expectRevert(bytes("activation predates deployment"));
        manifestHarness.validate(input);

        input = _manifestInput(splitter);
        input.startingReleaseSequence = uint256(type(uint64).max) + 1;
        vm.expectRevert(bytes("starting release sequence range"));
        manifestHarness.validate(input);

        input = _manifestInput(splitter);
        input.activationBlockNumber++;
        vm.expectRevert(bytes("manifest must run on activation fork"));
        manifestHarness.validate(input);
    }

    function testManifestUsesMinimalRpcBlockQuantities() public view {
        assertEq(manifestHarness.rpcBlockTag(0), "0x0");
        assertEq(manifestHarness.rpcBlockTag(15), "0xf");
        assertEq(manifestHarness.rpcBlockTag(256), "0x100");
        assertEq(manifestHarness.rpcBlockTag(45_573_030), "0x2b763a6");
    }

    function testManifestDerivesAndSerializesExactDeploymentPosition() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt = _deploymentReceipt(input, 7, 11, 7);

        (input.deploymentTransactionIndex, input.deploymentLogIndex) =
            manifestHarness.deploymentPositionFromReceipt(receipt, input);
        assertEq(input.deploymentTransactionIndex, 7);
        assertEq(input.deploymentLogIndex, 11);

        string memory output = "/tmp/daski-release-e2e/outcome-splitter-manifest.json";
        vm.createDir("/tmp/daski-release-e2e", true);
        vm.setEnv("STANDARD_RAIL_MANIFEST_OUTPUT", output);
        manifestHarness.writeManifest(input);
        string memory json = vm.readFile(output);
        assertEq(vm.parseJsonUint(json, ".splitterDeploymentTransactionIndex"), 7);
        assertEq(vm.parseJsonUint(json, ".splitterDeploymentLogIndex"), 11);
    }

    function testManifestRejectsInconsistentDeploymentEventPosition() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);

        vm.expectRevert(bytes("deployment event transaction index mismatch"));
        manifestHarness.deploymentPositionFromReceipt(_deploymentReceipt(input, 7, 11, 8), input);
    }

    function testManifestRejectsRevertedDeploymentReceipt() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt = vm.replace(_deploymentReceipt(input, 7, 11, 7), '"status":"0x1"', '"status":"0x0"');

        vm.expectRevert(bytes("deployment transaction reverted"));
        manifestHarness.deploymentPositionFromReceipt(receipt, input);
    }

    function testManifestRejectsWrongReceiptTarget() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt = vm.replace(
            _deploymentReceipt(input, 7, 11, 7),
            string.concat('"to":"', vm.toString(address(input.factory)), '"'),
            string.concat('"to":"', vm.toString(makeAddr("wrong-target")), '"')
        );

        vm.expectRevert(bytes("deployment receipt target mismatch"));
        manifestHarness.deploymentPositionFromReceipt(receipt, input);
    }

    function testManifestRejectsWrongReceiptBlockNumber() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt =
            vm.replace(_deploymentReceipt(input, 7, 11, 7), '"blockNumber":"0x64"', '"blockNumber":"0x65"');

        vm.expectRevert(bytes("deployment receipt block mismatch"));
        manifestHarness.deploymentPositionFromReceipt(receipt, input);
    }

    function testManifestRejectsWrongReceiptBlockHash() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt = vm.replace(
            _deploymentReceipt(input, 7, 11, 7),
            vm.toString(input.deploymentBlockHash),
            vm.toString(keccak256("wrong-block"))
        );

        vm.expectRevert(bytes("deployment receipt block hash mismatch"));
        manifestHarness.deploymentPositionFromReceipt(receipt, input);
    }

    function testManifestRejectsWrongEventSalt() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt = vm.replace(
            _deploymentReceipt(input, 7, 11, 7), vm.toString(input.deploymentSalt), vm.toString(keccak256("wrong-salt"))
        );

        vm.expectRevert(bytes("deployment event salt mismatch"));
        manifestHarness.deploymentPositionFromReceipt(receipt, input);
    }

    function testManifestRejectsWrongEventData() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        string memory receipt = vm.replace(
            _deploymentReceipt(input, 7, 11, 7),
            vm.toString(abi.encode(uint64(input.listingEpoch), input.listingHash)),
            vm.toString(abi.encode(uint64(input.listingEpoch) + 1, input.listingHash))
        );

        vm.expectRevert(bytes("deployment event data mismatch"));
        manifestHarness.deploymentPositionFromReceipt(receipt, input);
    }

    function testCounterfactualPrefundingDoesNotCensorDeployment() public {
        address predicted = OutcomeSplitterCreate2.computeAddress(address(factory), salt, _initCodeHash());
        token.mint(predicted, 19);

        assertEq(_deploy(), predicted);
        assertEq(token.balanceOf(predicted), 19);
        assertEq(OutcomeSplitter(payable(predicted)).releaseSequence(), 0);
    }

    function _deploy() private returns (address) {
        return factory.deploy(
            salt, block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );
    }

    function _initCodeHash() private view returns (bytes32) {
        return OutcomeSplitterCreate2.initCodeHash(
            block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );
    }

    function _manifestInput(OutcomeSplitter splitter)
        private
        view
        returns (WriteOutcomeSplitterManifest.ManifestInput memory input)
    {
        input.splitter = splitter;
        input.factory = factory;
        input.token = address(token);
        input.provider = provider;
        input.daski = daski;
        input.commissionBps = 500;
        input.policyHash = policyHash;
        input.outcomeHash = outcomeHash;
        input.listingHash = listingHash;
        input.listingEpoch = 1;
        input.deploymentSalt = salt;
        input.factoryRuntimeCodeHash = provenanceHarness.compiledFactoryRuntimeCodeHash();
        input.creationCodeHash = OutcomeSplitterCreate2.creationCodeHash();
        input.initCodeHash = _initCodeHash();
        input.deploymentTransaction = keccak256("deployment-transaction");
        input.deploymentBlockNumber = 100;
        input.deploymentBlockHash = keccak256("deployment-block");
        input.activationBlockNumber = 100;
        input.activationBlockHash = keccak256("activation-block");
        input.activationPosition = "END_OF_BLOCK";
        input.startingTokenBalance = 0;
        input.startingReleaseSequence = 0;
    }

    function _deploymentReceipt(
        WriteOutcomeSplitterManifest.ManifestInput memory input,
        uint256 transactionIndex,
        uint256 logIndex,
        uint256 logTransactionIndex
    ) private pure returns (string memory receipt) {
        receipt = string.concat(
            _receiptPrefix(input, transactionIndex),
            _deploymentLogTopics(input),
            vm.toString(abi.encode(uint64(input.listingEpoch), input.listingHash)),
            _deploymentLogPosition(input, logIndex, logTransactionIndex)
        );
    }

    function _receiptPrefix(WriteOutcomeSplitterManifest.ManifestInput memory input, uint256 transactionIndex)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"status":"0x1","transactionHash":"',
            vm.toString(input.deploymentTransaction),
            '","blockNumber":"0x64","blockHash":"',
            vm.toString(input.deploymentBlockHash),
            '","to":"',
            vm.toString(address(input.factory)),
            '","transactionIndex":"',
            vm.toString(bytes32(transactionIndex)),
            '","logs":['
        );
    }

    function _deploymentLogTopics(WriteOutcomeSplitterManifest.ManifestInput memory input)
        private
        pure
        returns (string memory)
    {
        bytes32 splitterTopic = bytes32(uint256(uint160(address(input.splitter))));
        return string.concat(
            '{"address":"',
            vm.toString(address(input.factory)),
            '","topics":["',
            vm.toString(keccak256("OutcomeSplitterDeployed(address,bytes32,bytes32,uint64,bytes32)")),
            '","',
            vm.toString(splitterTopic),
            '","',
            vm.toString(input.deploymentSalt),
            '","',
            vm.toString(input.outcomeHash),
            '"],"data":"'
        );
    }

    function _deploymentLogPosition(
        WriteOutcomeSplitterManifest.ManifestInput memory input,
        uint256 logIndex,
        uint256 logTransactionIndex
    ) private pure returns (string memory) {
        return string.concat(
            '","transactionHash":"',
            vm.toString(input.deploymentTransaction),
            '","blockNumber":"0x64","blockHash":"',
            vm.toString(input.deploymentBlockHash),
            '","transactionIndex":"',
            vm.toString(bytes32(logTransactionIndex)),
            '","logIndex":"',
            vm.toString(bytes32(logIndex)),
            '"}]}'
        );
    }
}
