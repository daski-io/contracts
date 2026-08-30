// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterScriptBase} from "./OutcomeSplitterScriptBase.sol";
import {StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @dev Forge v1.5.1 ABI-encodes JSON objects returned by `vm.rpc`. Declaring
///      the stable Base block prefix gives Solidity the matching return type;
///      later fields can be ignored because their offsets remain valid.
interface IManifestBlockRpc {
    struct BlockPrefix {
        bytes baseFeePerGas;
        bytes blobGasUsed;
        bytes difficulty;
        bytes excessBlobGas;
        bytes extraData;
        bytes gasLimit;
        bytes gasUsed;
        bytes hash;
        bytes logsBloom;
        bytes miner;
        bytes mixHash;
        bytes nonce;
        bytes number;
    }

    function rpc(string calldata urlOrAlias, string calldata method, string calldata params)
        external
        returns (BlockPrefix memory blockPrefix);
}

/// @notice Sole activation gate for a splitter, run on the claimed finalized activation fork.
contract WriteOutcomeSplitterManifest is OutcomeSplitterScriptBase {
    bytes32 private constant OUTCOME_SPLITTER_DEPLOYED_TOPIC =
        keccak256("OutcomeSplitterDeployed(address,bytes32,bytes32,uint64,bytes32)");
    uint256 private constant MAX_SAFE_JSON_INTEGER = 9_007_199_254_740_991;
    string private constant PRIMARY_RPC_URL_ENV = "STANDARD_RAIL_PRIMARY_RPC_URL";
    string private constant SECONDARY_RPC_URL_ENV = "STANDARD_RAIL_SECONDARY_RPC_URL";

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
        _validateActivationCheckpoint(input, vm.envString(PRIMARY_RPC_URL_ENV), vm.envString(SECONDARY_RPC_URL_ENV));
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
        require(input.activationBlockNumber >= input.deploymentBlockNumber, "activation predates deployment");
        require(input.activationBlockHash != bytes32(0), "zero activation block hash");
        require(keccak256(bytes(input.activationPosition)) == keccak256("END_OF_BLOCK"), "activation position mismatch");
        require(input.startingReleaseSequence <= type(uint64).max, "starting release sequence range");
        require(block.number == input.activationBlockNumber, "manifest must run on activation fork");

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

    function _validateActivationCheckpoint(
        ManifestInput memory input,
        string memory primaryRpcUrl,
        string memory secondaryRpcUrl
    ) internal {
        require(vm.getBlockNumber() == input.activationBlockNumber, "fork is not pinned at the activation block");
        require(
            _blockHeaderHash(input.activationBlockNumber) == input.activationBlockHash,
            "fork activation block hash mismatch"
        );
        _validateRpcEndpoints(primaryRpcUrl, secondaryRpcUrl);

        uint256 activationFork = vm.activeFork();
        uint256 expectedChainId = vm.getChainId();
        _validateRpcView(input, primaryRpcUrl, expectedChainId);
        _validateRpcView(input, secondaryRpcUrl, expectedChainId);
        vm.selectFork(activationFork);

        StandardRailCircleUSDC.validate(input.token, address(input.splitter), input.provider, input.daski);

        require(
            IERC20(input.token).balanceOf(address(input.splitter)) == input.startingTokenBalance,
            "starting token balance mismatch"
        );

        require(input.splitter.releaseSequence() == input.startingReleaseSequence, "starting release sequence mismatch");
    }

    function _validateRpcEndpoints(string memory primaryRpcUrl, string memory secondaryRpcUrl) internal pure {
        require(bytes(primaryRpcUrl).length != 0, "empty primary RPC URL");
        require(bytes(secondaryRpcUrl).length != 0, "empty secondary RPC URL");
        require(keccak256(bytes(primaryRpcUrl)) != keccak256(bytes(secondaryRpcUrl)), "RPC endpoints must be distinct");
    }

    function _validateRpcView(ManifestInput memory input, string memory rpcUrl, uint256 expectedChainId) internal {
        vm.createSelectFork(rpcUrl, input.activationBlockNumber);
        require(vm.getChainId() == expectedChainId, "RPC chain mismatch");

        bytes32 observedActivationHash = _blockHeaderHash(input.activationBlockNumber);
        IManifestBlockRpc.BlockPrefix memory finalizedBlock =
            IManifestBlockRpc(address(vm)).rpc(rpcUrl, "eth_getBlockByNumber", "[\"finalized\",false]");
        (uint256 finalizedBlockNumber, bytes32 reportedFinalizedHash) = _decodeFinalizedBlock(finalizedBlock);
        bytes32 observedFinalizedHash = _blockHeaderHash(finalizedBlockNumber);
        _validateActivationEvidence(
            input, observedActivationHash, finalizedBlockNumber, reportedFinalizedHash, observedFinalizedHash
        );
    }

    function _validateActivationEvidence(
        ManifestInput memory input,
        bytes32 observedActivationHash,
        uint256 finalizedBlockNumber,
        bytes32 reportedFinalizedHash,
        bytes32 observedFinalizedHash
    ) internal pure {
        require(observedActivationHash == input.activationBlockHash, "activation block hash mismatch");
        require(reportedFinalizedHash == observedFinalizedHash, "finalized block header mismatch");
        require(input.activationBlockNumber <= finalizedBlockNumber, "activation block is not finalized");
    }

    function _decodeFinalizedBlock(IManifestBlockRpc.BlockPrefix memory blockPrefix)
        internal
        pure
        returns (uint256 blockNumber, bytes32 blockHash)
    {
        blockNumber = _rpcQuantity(blockPrefix.number);
        require(blockPrefix.hash.length == 32, "invalid RPC block hash encoding");
        bytes memory encodedHash = blockPrefix.hash;
        assembly ("memory-safe") {
            blockHash := mload(add(encodedHash, 0x20))
        }
        require(blockHash != bytes32(0), "zero RPC block hash");
    }

    function _rpcQuantity(bytes memory value) internal pure returns (uint256 decoded) {
        require(value.length != 0 && value.length <= 32, "invalid RPC block number encoding");
        require(value.length == 1 || value[0] != bytes1(0), "noncanonical RPC block number");
        for (uint256 i = 0; i < value.length; i++) {
            decoded = (decoded << 8) | uint8(value[i]);
        }
    }

    function _blockHeaderHash(uint256 blockNumber) internal view virtual returns (bytes32) {
        return keccak256(vm.getRawBlockHeader(blockNumber));
    }

    function _deploymentPosition(ManifestInput memory input)
        internal
        returns (uint256 transactionIndex, uint256 logIndex)
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = OUTCOME_SPLITTER_DEPLOYED_TOPIC;
        VmSafe.EthGetLogs[] memory logs =
            vm.eth_getLogs(input.deploymentBlockNumber, input.deploymentBlockNumber, address(input.factory), topics);
        return _deploymentPositionFromLogs(logs, input);
    }

    /// @dev A matching log proves the deployment transaction succeeded (failed
    ///      transactions emit no logs) and that the factory itself emitted the
    ///      event; the typed fields replace every receipt-level check.
    function _deploymentPositionFromLogs(VmSafe.EthGetLogs[] memory logs, ManifestInput memory input)
        internal
        pure
        returns (uint256 transactionIndex, uint256 logIndex)
    {
        uint256 found = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].transactionHash == input.deploymentTransaction) {
                require(found == type(uint256).max, "duplicate deployment events in transaction");
                found = i;
            }
        }
        require(found != type(uint256).max, "deployment event not found in block");
        VmSafe.EthGetLogs memory log = logs[found];
        require(log.emitter == address(input.factory), "deployment event factory mismatch");
        require(!log.removed, "deployment event removed by reorg");
        require(log.blockNumber == input.deploymentBlockNumber, "deployment event block mismatch");
        require(log.blockHash == input.deploymentBlockHash, "deployment event block hash mismatch");
        require(log.topics.length == 4, "deployment event topics mismatch");
        require(log.topics[0] == OUTCOME_SPLITTER_DEPLOYED_TOPIC, "deployment event signature mismatch");
        require(
            log.topics[1] == bytes32(uint256(uint160(address(input.splitter)))), "deployment event splitter mismatch"
        );
        require(log.topics[2] == input.deploymentSalt, "deployment event salt mismatch");
        require(log.topics[3] == input.outcomeHash, "deployment event outcome mismatch");
        require(
            keccak256(log.data) == keccak256(abi.encode(uint64(input.listingEpoch), input.listingHash)),
            "deployment event data mismatch"
        );
        transactionIndex = log.transactionIndex;
        logIndex = log.logIndex;
        require(transactionIndex <= MAX_SAFE_JSON_INTEGER, "deployment transaction index range");
        require(logIndex <= MAX_SAFE_JSON_INTEGER, "deployment log index range");
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
