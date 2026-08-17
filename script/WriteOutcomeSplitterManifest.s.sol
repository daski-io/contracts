// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {IOutcomeSplitter} from "../src/interfaces/IOutcomeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterScriptBase} from "./OutcomeSplitterScriptBase.sol";

/// @notice Validates a deployed splitter and writes the public manifest input.
contract WriteOutcomeSplitterManifest is OutcomeSplitterScriptBase {
    using Strings for uint256;

    bytes32 private constant OUTCOME_SPLITTER_DEPLOYED_TOPIC =
        keccak256("OutcomeSplitterDeployed(address,bytes32,bytes32,uint64,bytes32)");
    uint256 private constant MAX_SAFE_JSON_INTEGER = 9_007_199_254_740_991;

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
        uint256 deploymentTransactionIndex;
        uint256 deploymentLogIndex;
        bytes32 factoryRuntimeCodeHash;
        bytes32 creationCodeHash;
        bytes32 initCodeHash;
        uint256 activationBlockNumber;
        bytes32 activationBlockHash;
        string activationPosition;
        uint256 startingTokenBalance;
        uint256 startingReleaseSequence;
    }

    function run() external returns (string memory json) {
        ManifestInput memory input = _readInput();
        _validate(input);
        (input.deploymentTransactionIndex, input.deploymentLogIndex) = _deploymentPosition(input);
        _validateActivationCheckpoint(input);
        json = _writeManifest(input);
    }

    function _readInput() internal view returns (ManifestInput memory input) {
        input.splitter = OutcomeSplitter(payable(vm.envAddress("STANDARD_RAIL_SPLITTER_ADDRESS")));
        input.factory = OutcomeSplitterFactory(vm.envAddress("STANDARD_RAIL_SPLITTER_FACTORY"));
        input.token = vm.envAddress("STANDARD_RAIL_CANONICAL_TOKEN");
        input.provider = vm.envAddress("STANDARD_RAIL_PROVIDER_PAYEE");
        input.daski = vm.envAddress("STANDARD_RAIL_DASKI_COMMISSION_RECEIVER");
        input.commissionBps = vm.envOr("MARKETPLACE_COMMISSION_BPS", uint256(500));
        input.policyHash = vm.envBytes32("STANDARD_RAIL_POLICY_VERSION_HASH");
        input.outcomeHash = vm.envBytes32("STANDARD_RAIL_OUTCOME_ID_HASH");
        input.listingHash = vm.envBytes32("STANDARD_RAIL_LISTING_COMMITMENT_HASH");
        input.listingEpoch = vm.envUint("STANDARD_RAIL_LISTING_EPOCH");
        input.deploymentSalt = vm.envBytes32("STANDARD_RAIL_DEPLOYMENT_SALT");
        input.deploymentTransaction = vm.envBytes32("STANDARD_RAIL_SPLITTER_DEPLOYMENT_TX");
        input.deploymentBlockNumber = vm.envUint("STANDARD_RAIL_SPLITTER_DEPLOYMENT_BLOCK_NUMBER");
        input.deploymentBlockHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_DEPLOYMENT_BLOCK_HASH");
        input.factoryRuntimeCodeHash = vm.envBytes32(FACTORY_RUNTIME_CODE_HASH_ENV);
        input.creationCodeHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_CREATION_CODE_HASH");
        input.initCodeHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_INIT_CODE_HASH");
        input.activationBlockNumber = vm.envUint("STANDARD_RAIL_SPLITTER_ACTIVATION_BLOCK_NUMBER");
        input.activationBlockHash = vm.envBytes32("STANDARD_RAIL_SPLITTER_ACTIVATION_BLOCK_HASH");
        input.activationPosition = vm.envString("STANDARD_RAIL_SPLITTER_ACTIVATION_POSITION");
        input.startingTokenBalance = vm.envUint("STANDARD_RAIL_SPLITTER_STARTING_TOKEN_BALANCE");
        input.startingReleaseSequence = vm.envUint("STANDARD_RAIL_SPLITTER_STARTING_RELEASE_SEQUENCE");
    }

    function _validate(ManifestInput memory input) internal view {
        OutcomeSplitter splitter = input.splitter;
        require(address(splitter).code.length != 0, "splitter has no code");
        _validateReviewedFactory(address(input.factory), input.factoryRuntimeCodeHash);
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
        require(input.activationBlockNumber >= input.deploymentBlockNumber, "activation predates deployment");
        require(input.activationBlockHash != bytes32(0), "zero activation block hash");
        require(keccak256(bytes(input.activationPosition)) == keccak256("END_OF_BLOCK"), "activation position mismatch");
        require(input.startingReleaseSequence <= type(uint64).max, "starting release sequence range");
        require(
            OutcomeSplitterCreate2.creationCodeHash() == input.creationCodeHash, "splitter creation code hash mismatch"
        );
        bytes32 localInitCodeHash = _initCodeHash(input);
        require(localInitCodeHash == input.initCodeHash, "splitter init code hash mismatch");
        require(
            OutcomeSplitterCreate2.computeAddress(address(input.factory), input.deploymentSalt, localInitCodeHash)
                == address(splitter),
            "local CREATE2 provenance mismatch"
        );
    }

    function _validateActivationCheckpoint(ManifestInput memory input) internal {
        bytes memory finalizedBlock = vm.rpc("eth_getBlockByNumber", "[\"finalized\",false]");
        uint256 finalizedBlockNumber = vm.parseJsonUint(string(finalizedBlock), ".number");
        require(input.activationBlockNumber <= finalizedBlockNumber, "activation block is not finalized");

        string memory blockTag = _rpcBlockTag(input.activationBlockNumber);
        bytes memory activationBlock = vm.rpc("eth_getBlockByNumber", string.concat("[\"", blockTag, "\",false]"));
        require(
            vm.parseJsonUint(string(activationBlock), ".number") == input.activationBlockNumber,
            "activation block number mismatch"
        );
        require(
            vm.parseJsonBytes32(string(activationBlock), ".hash") == input.activationBlockHash,
            "activation block hash mismatch"
        );

        uint256 historicalBalance =
            _historicalWord(input.token, abi.encodeCall(IERC20.balanceOf, (address(input.splitter))), blockTag);
        require(historicalBalance == input.startingTokenBalance, "starting token balance mismatch");

        uint256 historicalReleaseSequence =
            _historicalWord(address(input.splitter), abi.encodeCall(IOutcomeSplitter.releaseSequence, ()), blockTag);
        require(historicalReleaseSequence == input.startingReleaseSequence, "starting release sequence mismatch");
    }

    function _deploymentPosition(ManifestInput memory input)
        internal
        returns (uint256 transactionIndex, uint256 logIndex)
    {
        bytes memory receipt = vm.rpc(
            "eth_getTransactionReceipt", string.concat("[\"", vm.toString(input.deploymentTransaction), "\"]")
        );
        return _deploymentPositionFromReceipt(string(receipt), input);
    }

    function _deploymentPositionFromReceipt(string memory receipt, ManifestInput memory input)
        internal
        pure
        returns (uint256 transactionIndex, uint256 logIndex)
    {
        require(vm.parseJsonUint(receipt, ".status") == 1, "deployment transaction reverted");
        require(
            vm.parseJsonBytes32(receipt, ".transactionHash") == input.deploymentTransaction,
            "deployment receipt transaction mismatch"
        );
        require(
            vm.parseJsonUint(receipt, ".blockNumber") == input.deploymentBlockNumber,
            "deployment receipt block mismatch"
        );
        require(
            vm.parseJsonBytes32(receipt, ".blockHash") == input.deploymentBlockHash,
            "deployment receipt block hash mismatch"
        );
        require(vm.parseJsonAddress(receipt, ".to") == address(input.factory), "deployment receipt target mismatch");

        transactionIndex = vm.parseJsonUint(receipt, ".transactionIndex");
        require(transactionIndex <= MAX_SAFE_JSON_INTEGER, "deployment transaction index range");

        string memory logPath = ".logs[0]";
        require(
            vm.parseJsonAddress(receipt, string.concat(logPath, ".address")) == address(input.factory),
            "deployment event factory mismatch"
        );
        bytes32[] memory topics = vm.parseJsonBytes32Array(receipt, string.concat(logPath, ".topics"));
        require(topics.length == 4, "deployment event topics mismatch");
        require(topics[0] == OUTCOME_SPLITTER_DEPLOYED_TOPIC, "deployment event signature mismatch");
        require(topics[1] == bytes32(uint256(uint160(address(input.splitter)))), "deployment event splitter mismatch");
        require(topics[2] == input.deploymentSalt, "deployment event salt mismatch");
        require(topics[3] == input.outcomeHash, "deployment event outcome mismatch");
        require(
            keccak256(vm.parseJsonBytes(receipt, string.concat(logPath, ".data")))
                == keccak256(abi.encode(uint64(input.listingEpoch), input.listingHash)),
            "deployment event data mismatch"
        );
        require(
            vm.parseJsonBytes32(receipt, string.concat(logPath, ".transactionHash")) == input.deploymentTransaction,
            "deployment event transaction mismatch"
        );
        require(
            vm.parseJsonUint(receipt, string.concat(logPath, ".blockNumber")) == input.deploymentBlockNumber,
            "deployment event block mismatch"
        );
        require(
            vm.parseJsonBytes32(receipt, string.concat(logPath, ".blockHash")) == input.deploymentBlockHash,
            "deployment event block hash mismatch"
        );
        require(
            vm.parseJsonUint(receipt, string.concat(logPath, ".transactionIndex")) == transactionIndex,
            "deployment event transaction index mismatch"
        );
        logIndex = vm.parseJsonUint(receipt, string.concat(logPath, ".logIndex"));
        require(logIndex <= MAX_SAFE_JSON_INTEGER, "deployment log index range");
    }

    function _historicalWord(address target, bytes memory callData, string memory blockTag)
        internal
        returns (uint256 value)
    {
        bytes memory result = vm.rpc(
            "eth_call",
            string.concat(
                "[{\"to\":\"", vm.toString(target), "\",\"data\":\"", vm.toString(callData), "\"},\"", blockTag, "\"]"
            )
        );
        require(result.length == 32, "invalid historical eth_call result");
        value = abi.decode(result, (uint256));
    }

    function _rpcBlockTag(uint256 blockNumber) internal pure returns (string memory) {
        bytes memory padded = bytes(blockNumber.toHexString());
        uint256 firstDigit = 2;
        while (firstDigit + 1 < padded.length && padded[firstDigit] == 0x30) {
            firstDigit++;
        }

        bytes memory minimal = new bytes(padded.length - firstDigit + 2);
        minimal[0] = 0x30;
        minimal[1] = 0x78;
        for (uint256 i = firstDigit; i < padded.length; i++) {
            minimal[i - firstDigit + 2] = padded[i];
        }
        return string(minimal);
    }

    function _initCodeHash(ManifestInput memory input) internal view returns (bytes32) {
        require(input.commissionBps <= type(uint16).max, "commission range");
        require(input.listingEpoch <= type(uint64).max, "epoch range");
        // Values are range checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 commissionBps16 = uint16(input.commissionBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 listingEpoch64 = uint64(input.listingEpoch);
        return OutcomeSplitterCreate2.initCodeHash(
            block.chainid,
            input.token,
            input.provider,
            input.daski,
            commissionBps16,
            input.policyHash,
            input.outcomeHash,
            input.listingHash,
            listingEpoch64
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
        vm.serializeBytes32(object, "splitterFactoryRuntimeCodeHash", input.factoryRuntimeCodeHash);
        vm.serializeBytes32(object, "splitterDeploymentSalt", input.deploymentSalt);
        vm.serializeBytes(object, "splitterCreationCode", type(OutcomeSplitter).creationCode);
        vm.serializeBytes32(object, "splitterCreationCodeHash", input.creationCodeHash);
        vm.serializeBytes32(object, "splitterInitCodeHash", input.initCodeHash);
        vm.serializeBytes32(object, "splitterDeploymentTransaction", input.deploymentTransaction);
        vm.serializeUint(object, "splitterDeploymentBlockNumber", input.deploymentBlockNumber);
        vm.serializeBytes32(object, "splitterDeploymentBlockHash", input.deploymentBlockHash);
        vm.serializeUint(object, "splitterDeploymentTransactionIndex", input.deploymentTransactionIndex);
        vm.serializeUint(object, "splitterDeploymentLogIndex", input.deploymentLogIndex);
        vm.serializeUint(object, "splitterActivationBlockNumber", input.activationBlockNumber);
        vm.serializeBytes32(object, "splitterActivationBlockHash", input.activationBlockHash);
        vm.serializeString(object, "splitterActivationPosition", input.activationPosition);
        vm.serializeUint(object, "splitterStartingTokenBalance", input.startingTokenBalance);
        vm.serializeUint(object, "splitterStartingReleaseSequence", input.startingReleaseSequence);
        vm.serializeBytes32(object, "splitterRuntimeCodeHash", address(input.splitter).codehash);
        json = vm.serializeBytes32(object, "splitterImmutableHash", _immutableHash(input));
        vm.writeJson(json, vm.envString("STANDARD_RAIL_MANIFEST_OUTPUT"));
    }
}
