// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterScriptBase} from "../script/OutcomeSplitterScriptBase.sol";
import {IManifestBlockRpc, WriteOutcomeSplitterManifest} from "../script/WriteOutcomeSplitterManifest.s.sol";
import {VmSafe} from "forge-std/Vm.sol";
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

    function deploymentPositionFromLogs(VmSafe.EthGetLogs[] memory logs, ManifestInput memory input)
        external
        pure
        returns (uint256 transactionIndex, uint256 logIndex)
    {
        return _deploymentPositionFromLogs(logs, input);
    }

    function writeManifest(ManifestInput memory input) external returns (string memory) {
        return _writeManifest(input);
    }

    function validateRpcEndpoints(string memory primaryRpcUrl, string memory secondaryRpcUrl) external pure {
        _validateRpcEndpoints(primaryRpcUrl, secondaryRpcUrl);
    }

    function validateActivationEvidence(
        ManifestInput memory input,
        bytes32 observedActivationHash,
        uint256 finalizedBlockNumber,
        bytes32 reportedFinalizedHash,
        bytes32 observedFinalizedHash
    ) external pure {
        _validateActivationEvidence(
            input, observedActivationHash, finalizedBlockNumber, reportedFinalizedHash, observedFinalizedHash
        );
    }

    function decodeFinalizedBlock(IManifestBlockRpc.BlockPrefix memory blockPrefix)
        external
        pure
        returns (uint256 blockNumber, bytes32 blockHash)
    {
        return _decodeFinalizedBlock(blockPrefix);
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

    function testManifestRequiresDistinctRpcEndpoints() public {
        manifestHarness.validateRpcEndpoints("https://primary.invalid", "https://secondary.invalid");

        vm.expectRevert(bytes("empty primary RPC URL"));
        manifestHarness.validateRpcEndpoints("", "https://secondary.invalid");

        vm.expectRevert(bytes("empty secondary RPC URL"));
        manifestHarness.validateRpcEndpoints("https://primary.invalid", "");

        vm.expectRevert(bytes("RPC endpoints must be distinct"));
        manifestHarness.validateRpcEndpoints("https://same.invalid", "https://same.invalid");
    }

    function testManifestBindsActivationHashAndFinalityEvidence() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        bytes32 finalizedHash = keccak256("finalized-block");

        manifestHarness.validateActivationEvidence(
            input, input.activationBlockHash, input.activationBlockNumber, finalizedHash, finalizedHash
        );

        vm.expectRevert(bytes("activation block hash mismatch"));
        manifestHarness.validateActivationEvidence(
            input, keccak256("attacker-supplied-block"), input.activationBlockNumber, finalizedHash, finalizedHash
        );

        vm.expectRevert(bytes("finalized block header mismatch"));
        manifestHarness.validateActivationEvidence(
            input,
            input.activationBlockHash,
            input.activationBlockNumber,
            finalizedHash,
            keccak256("different-finalized-block")
        );

        vm.expectRevert(bytes("activation block is not finalized"));
        manifestHarness.validateActivationEvidence(
            input, input.activationBlockHash, input.activationBlockNumber - 1, finalizedHash, finalizedHash
        );
    }

    function testManifestDecodesTypedFinalizedBlockPrefix() public view {
        IManifestBlockRpc.BlockPrefix memory blockPrefix;
        bytes32 finalizedHash = keccak256("finalized-block");
        blockPrefix.hash = abi.encodePacked(finalizedHash);
        blockPrefix.number = hex"64";

        (uint256 blockNumber, bytes32 blockHash) = manifestHarness.decodeFinalizedBlock(blockPrefix);
        assertEq(blockNumber, 100);
        assertEq(blockHash, finalizedHash);
    }

    function testManifestRejectsMalformedTypedFinalizedBlockPrefix() public {
        IManifestBlockRpc.BlockPrefix memory blockPrefix;
        blockPrefix.hash = abi.encodePacked(keccak256("finalized-block"));

        vm.expectRevert(bytes("invalid RPC block number encoding"));
        manifestHarness.decodeFinalizedBlock(blockPrefix);

        blockPrefix.number = hex"0064";
        vm.expectRevert(bytes("noncanonical RPC block number"));
        manifestHarness.decodeFinalizedBlock(blockPrefix);

        blockPrefix.number = hex"64";
        blockPrefix.hash = new bytes(31);
        vm.expectRevert(bytes("invalid RPC block hash encoding"));
        manifestHarness.decodeFinalizedBlock(blockPrefix);

        blockPrefix.hash = new bytes(32);
        vm.expectRevert(bytes("zero RPC block hash"));
        manifestHarness.decodeFinalizedBlock(blockPrefix);
    }

    function testManifestDerivesAndSerializesExactDeploymentPosition() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        (input.deploymentTransactionIndex, input.deploymentLogIndex) =
            manifestHarness.deploymentPositionFromLogs(_deploymentLogs(input, 7, 11), input);
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

    function testManifestRejectsMissingDeploymentEvent() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].transactionHash = keccak256("some-other-transaction");

        vm.expectRevert(bytes("deployment event not found in block"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsDuplicateDeploymentEvents() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory one = _deploymentLogs(input, 7, 11);
        VmSafe.EthGetLogs[] memory logs = new VmSafe.EthGetLogs[](2);
        logs[0] = one[0];
        logs[1] = one[0];

        vm.expectRevert(bytes("duplicate deployment events in transaction"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsForeignEmitter() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].emitter = makeAddr("foreign-emitter");

        vm.expectRevert(bytes("deployment event factory mismatch"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsReorgRemovedEvent() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].removed = true;

        vm.expectRevert(bytes("deployment event removed by reorg"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsWrongEventBlockNumber() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].blockNumber += 1;

        vm.expectRevert(bytes("deployment event block mismatch"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsWrongEventBlockHash() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].blockHash = keccak256("wrong-block");

        vm.expectRevert(bytes("deployment event block hash mismatch"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsWrongEventSalt() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].topics[2] = keccak256("wrong-salt");

        vm.expectRevert(bytes("deployment event salt mismatch"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsWrongEventOutcome() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].topics[3] = keccak256("wrong-outcome");

        vm.expectRevert(bytes("deployment event outcome mismatch"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
    }

    function testManifestRejectsWrongEventData() public {
        OutcomeSplitter splitter = OutcomeSplitter(payable(_deploy()));
        WriteOutcomeSplitterManifest.ManifestInput memory input = _manifestInput(splitter);
        VmSafe.EthGetLogs[] memory logs = _deploymentLogs(input, 7, 11);
        logs[0].data = abi.encode(uint64(input.listingEpoch) + 1, input.listingHash);

        vm.expectRevert(bytes("deployment event data mismatch"));
        manifestHarness.deploymentPositionFromLogs(logs, input);
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

    function _deploymentLogs(
        WriteOutcomeSplitterManifest.ManifestInput memory input,
        uint256 transactionIndex,
        uint256 logIndex
    ) private pure returns (VmSafe.EthGetLogs[] memory logs) {
        bytes32[] memory topics = new bytes32[](4);
        topics[0] = keccak256("OutcomeSplitterDeployed(address,bytes32,bytes32,uint64,bytes32)");
        topics[1] = bytes32(uint256(uint160(address(input.splitter))));
        topics[2] = input.deploymentSalt;
        topics[3] = input.outcomeHash;
        logs = new VmSafe.EthGetLogs[](1);
        logs[0] = VmSafe.EthGetLogs({
            emitter: address(input.factory),
            topics: topics,
            data: abi.encode(uint64(input.listingEpoch), input.listingHash),
            blockHash: input.deploymentBlockHash,
            blockNumber: uint64(input.deploymentBlockNumber),
            transactionHash: input.deploymentTransaction,
            transactionIndex: uint64(transactionIndex),
            logIndex: logIndex,
            removed: false
        });
    }
}
