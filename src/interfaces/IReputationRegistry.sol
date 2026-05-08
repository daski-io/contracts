// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IReputationRegistry — ERC-8004 Reputation Registry interface
/// @notice Pinned to ERC-8004 draft spec commit
///         503591a6e80e6e1affdd6403341e25269141f046. See IIdentityRegistry.sol
///         for the full reference.
interface IReputationRegistry {
    // -- Events -----------------------------------------------------------

    /// @dev `tag1` is emitted twice on purpose, per ERC-8004:
    ///      * `indexedTag1` is an `indexed` string parameter — the EVM
    ///        stores indexed strings as the keccak256 hash of the value in
    ///        the topic, so off-chain consumers filtering by topic must
    ///        first hash the tag string they're looking for.
    ///      * `tag1` is the same string emitted as a non-indexed parameter
    ///        in the data payload, so consumers can read the original
    ///        string value once a matching event is found.
    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        int128 value,
        uint8 valueDecimals,
        string indexed indexedTag1,
        string tag1,
        string tag2,
        string endpoint,
        string feedbackURI,
        bytes32 feedbackHash
    );

    event FeedbackRevoked(uint256 indexed agentId, address indexed clientAddress, uint64 indexed feedbackIndex);

    event ResponseAppended(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        address indexed responder,
        string responseURI,
        bytes32 responseHash
    );

    // -- Utility ----------------------------------------------------------

    function getIdentityRegistry() external view returns (address identityRegistry);

    // -- Feedback submission ----------------------------------------------

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;

    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseURI,
        bytes32 responseHash
    ) external;

    // -- Reads ------------------------------------------------------------

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked);

    function getClients(uint256 agentId) external view returns (address[] memory);

    function getClientCount(uint256 agentId) external view returns (uint256);

    function getClientsPaginated(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page);

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
}
