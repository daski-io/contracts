// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ERC-8004 Reputation Registry
// Pinned to draft spec commit 503591a6e80e6e1affdd6403341e25269141f046.
// Source: https://github.com/ethereum/ERCs/blob/503591a6/ERCS/erc-8004.md

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice ERC-8004 Reputation Registry. Feedback is per-(agent, client)
///         storage; the heavier fields (endpoint, URI, hash) are only
///         emitted. Revocation is soft — record stays, `isRevoked` flips.
///
/// Per spec:
///   * Feedback submitter MUST NOT be the agent owner or an approved operator.
///   * valueDecimals MUST be between 0 and 18.
contract ReputationRegistry is Initializable, UUPSUpgradeable, IReputationRegistry {
    struct FeedbackRecord {
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
        bool isRevoked;
        bool exists;
    }

    struct ResponseRecord {
        address responder;
        string responseURI;
        bytes32 responseHash;
    }

    address public admin;
    address public pendingAdmin;
    IERC721 public identityRegistry;

    // agentId → clientAddress → feedbackIndex (1-indexed) → record
    mapping(uint256 => mapping(address => mapping(uint64 => FeedbackRecord))) private _feedback;
    // agentId → clientAddress → next feedback index (lastIndex + 1)
    mapping(uint256 => mapping(address => uint64)) private _nextIndex;
    // agentId → list of distinct clients (for getClients)
    mapping(uint256 => address[]) private _clients;
    mapping(uint256 => mapping(address => bool)) private _knownClient;

    // agentId → clientAddress → feedbackIndex → responses
    mapping(uint256 => mapping(address => mapping(uint64 => ResponseRecord[]))) private _responses;

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address identityRegistry_, address _admin) external initializer {
        require(identityRegistry_ != address(0), "zero identity");
        require(_admin != address(0), "zero admin");
        identityRegistry = IERC721(identityRegistry_);
        admin = _admin;
    }

    function getIdentityRegistry() external view override returns (address) {
        return address(identityRegistry);
    }

    // ------------------------------------------------------------------
    // Feedback
    // ------------------------------------------------------------------

    struct FeedbackInput {
        uint256 agentId;
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
        string endpoint;
        string feedbackURI;
        bytes32 feedbackHash;
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external override {
        require(valueDecimals <= 18, "valueDecimals > 18");
        _requireArmsLength(agentId, msg.sender);

        FeedbackInput memory input = FeedbackInput({
            agentId: agentId,
            value: value,
            valueDecimals: valueDecimals,
            tag1: tag1,
            tag2: tag2,
            endpoint: endpoint,
            feedbackURI: feedbackURI,
            feedbackHash: feedbackHash
        });
        _recordAndEmit(input);
    }

    function _requireArmsLength(uint256 agentId, address client) internal view {
        address owner = _ownerOfAgent(agentId);
        // Spec: submitter MUST NOT be the agent owner or an approved operator.
        // ERC-721 has two flavors of approval — operator-for-all and
        // per-token approved address — and both grant control over the
        // agent. Excluding only one leaves a self-review hole.
        require(client != owner, "owner cannot self-review");
        require(!identityRegistry.isApprovedForAll(owner, client), "operator cannot review");
        require(identityRegistry.getApproved(agentId) != client, "approved spender cannot review");
    }

    function _recordAndEmit(FeedbackInput memory input) internal {
        uint64 index = ++_nextIndex[input.agentId][msg.sender];

        _feedback[input.agentId][msg.sender][index] = FeedbackRecord({
            value: input.value,
            valueDecimals: input.valueDecimals,
            tag1: input.tag1,
            tag2: input.tag2,
            isRevoked: false,
            exists: true
        });

        if (!_knownClient[input.agentId][msg.sender]) {
            _knownClient[input.agentId][msg.sender] = true;
            _clients[input.agentId].push(msg.sender);
        }

        emit NewFeedback(
            input.agentId,
            msg.sender,
            index,
            input.value,
            input.valueDecimals,
            input.tag1,
            input.tag1,
            input.tag2,
            input.endpoint,
            input.feedbackURI,
            input.feedbackHash
        );
    }

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external override {
        FeedbackRecord storage rec = _feedback[agentId][msg.sender][feedbackIndex];
        require(rec.exists, "no such feedback");
        require(!rec.isRevoked, "already revoked");
        rec.isRevoked = true;
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }

    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseURI,
        bytes32 responseHash
    ) external override {
        require(_feedback[agentId][clientAddress][feedbackIndex].exists, "no such feedback");
        _responses[agentId][clientAddress][feedbackIndex].push(
            ResponseRecord({responder: msg.sender, responseURI: responseURI, responseHash: responseHash})
        );
        emit ResponseAppended(agentId, clientAddress, feedbackIndex, msg.sender, responseURI, responseHash);
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        override
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked)
    {
        FeedbackRecord storage rec = _feedback[agentId][clientAddress][feedbackIndex];
        require(rec.exists, "no such feedback");
        return (rec.value, rec.valueDecimals, rec.tag1, rec.tag2, rec.isRevoked);
    }

    function getClients(uint256 agentId) external view override returns (address[] memory) {
        return _clients[agentId];
    }

    function getLastIndex(uint256 agentId, address clientAddress) external view override returns (uint64) {
        return _nextIndex[agentId][clientAddress];
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _ownerOfAgent(uint256 agentId) internal view returns (address) {
        // Reverts with ERC721NonexistentToken if agentId is not minted, which
        // satisfies the spec's "agentId must be a validly registered agent".
        return identityRegistry.ownerOf(agentId);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
