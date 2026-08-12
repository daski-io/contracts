// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IIdentityRegistry — ERC-8004 Identity Registry interface
/// @notice Pinned to ERC-8004 draft spec commit
///         503591a6e80e6e1affdd6403341e25269141f046
///         (ethereum/ERCs, merged 2026-01-25, "Updates from community feedback").
///         Source: https://github.com/ethereum/ERCs/blob/503591a6/ERCS/erc-8004.md
/// @dev Each agent is identified by a uint256 agentId (ERC-721 tokenId). The
///      agentURI (tokenURI) resolves to the agent registration file. This is
///      an ERC-721 with URIStorage; the NFT interface is inherited separately.
interface IIdentityRegistry {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    // -- Events (must match the spec exactly) -----------------------------

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(
        uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue
    );

    // -- Registration -----------------------------------------------------

    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId);

    function register(string calldata agentURI) external returns (uint256 agentId);

    function register() external returns (uint256 agentId);

    // -- Agent URI --------------------------------------------------------

    function setAgentURI(uint256 agentId, string calldata newURI) external;

    // -- Metadata ---------------------------------------------------------

    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory);
    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue) external;

    // -- Agent wallet (EIP-712/ERC-1271 signature required) ---------------

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;
    function getAgentWallet(uint256 agentId) external view returns (address);
    function unsetAgentWallet(uint256 agentId) external;
}
