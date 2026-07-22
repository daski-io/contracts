// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";

/// @notice Test double for the CANONICAL ERC-8004 IdentityRegistry (the
///         0x8004A... per-chain singleton). Mirrors the canonical surface the
///         Daski stack depends on:
///           * ERC-721 + URIStorage; register() / register(uri) /
///             register(uri, metadata) minting to msg.sender
///           * setAgentURI; metadata key/value with reserved "agentWallet"
///           * setAgentWallet (EIP-712/ERC-1271 signature of the new wallet,
///             current owner binding, five-minute deadline) /
///             unsetAgentWallet / getAgentWallet
///           * identifiers start at 0, agentWallet is initialized to the
///             registrant, and is cleared on every transfer
///
///         Deliberately ABSENT (Daski extensions the canonical registry does
///         not have): agentOfWallet, registerBySig, the 1:1 wallet↔agent
///         invariant.
contract MockCanonicalIdentityRegistry is ERC721URIStorage, EIP712, IIdentityRegistry {
    string internal constant AGENT_WALLET_KEY = "agentWallet";
    uint256 public constant MAX_DEADLINE_DELAY = 5 minutes;

    bytes32 public constant SET_AGENT_WALLET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");

    uint256 private _nextAgentId;

    mapping(uint256 => mapping(string => bytes)) private _metadata;
    mapping(uint256 => address) private _agentWallet;

    constructor() ERC721("AgentIdentity", "AGENT") EIP712("ERC8004IdentityRegistry", "1") {}

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function register(string calldata agentURI, MetadataEntry[] calldata metadata)
        external
        override
        returns (uint256 agentId)
    {
        agentId = _register(msg.sender, agentURI);
        for (uint256 i = 0; i < metadata.length; i++) {
            require(
                keccak256(bytes(metadata[i].metadataKey)) != keccak256(bytes(AGENT_WALLET_KEY)),
                "agentWallet is reserved"
            );
            _metadata[agentId][metadata[i].metadataKey] = metadata[i].metadataValue;
            emit MetadataSet(agentId, metadata[i].metadataKey, metadata[i].metadataKey, metadata[i].metadataValue);
        }
    }

    function register(string calldata agentURI) external override returns (uint256 agentId) {
        agentId = _register(msg.sender, agentURI);
    }

    function register() external override returns (uint256 agentId) {
        agentId = _register(msg.sender, "");
    }

    function _register(address owner, string memory agentURI) internal returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _agentWallet[agentId] = owner;
        _safeMint(owner, agentId);
        if (bytes(agentURI).length > 0) {
            _setTokenURI(agentId, agentURI);
        }
        emit MetadataSet(agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, abi.encodePacked(owner));
        emit Registered(agentId, agentURI, owner);
    }

    // ------------------------------------------------------------------
    // Agent URI
    // ------------------------------------------------------------------

    function setAgentURI(uint256 agentId, string calldata newURI) external override {
        _requireOwnerOrApproved(agentId);
        _setTokenURI(agentId, newURI);
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    // ------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------

    function getMetadata(uint256 agentId, string memory metadataKey) external view override returns (bytes memory) {
        if (keccak256(bytes(metadataKey)) == keccak256(bytes(AGENT_WALLET_KEY))) {
            address w = _agentWallet[agentId];
            return w == address(0) ? bytes("") : abi.encodePacked(w);
        }
        return _metadata[agentId][metadataKey];
    }

    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue) external override {
        _requireOwnerOrApproved(agentId);
        require(keccak256(bytes(metadataKey)) != keccak256(bytes(AGENT_WALLET_KEY)), "agentWallet is reserved");
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    // ------------------------------------------------------------------
    // Agent wallet
    // ------------------------------------------------------------------

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature)
        external
        override
    {
        _requireOwnerOrApproved(agentId);
        require(block.timestamp <= deadline, "signature expired");
        require(deadline <= block.timestamp + MAX_DEADLINE_DELAY, "deadline too far");
        require(newWallet != address(0), "zero wallet");

        address owner = ownerOf(agentId);
        bytes32 structHash = keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, owner, deadline));
        require(
            SignatureChecker.isValidSignatureNow(newWallet, _hashTypedDataV4(structHash), signature),
            "invalid wallet signature"
        );

        _agentWallet[agentId] = newWallet;
        emit MetadataSet(agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, abi.encodePacked(newWallet));
    }

    function getAgentWallet(uint256 agentId) external view override returns (address) {
        return _agentWallet[agentId];
    }

    function unsetAgentWallet(uint256 agentId) external override {
        _requireOwnerOrApproved(agentId);
        delete _agentWallet[agentId];
        emit MetadataSet(agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, bytes(""));
    }

    /// @dev TEST-ONLY fixture cheat, not part of the canonical surface: set
    ///      an agent's payment wallet without the EIP-712 ceremony. Tests
    ///      exercising real rotation semantics must use setAgentWallet.
    function forceSetAgentWallet(uint256 agentId, address wallet) external {
        _requireOwned(agentId);
        _agentWallet[agentId] = wallet;
    }

    // ------------------------------------------------------------------
    // ERC-721 hooks: auto-clear agentWallet on transfer (spec behavior)
    // ------------------------------------------------------------------

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            if (_agentWallet[tokenId] != address(0)) {
                delete _agentWallet[tokenId];
                emit MetadataSet(tokenId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, bytes(""));
            }
        }
        return super._update(to, tokenId, auth);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _requireOwnerOrApproved(uint256 tokenId) internal view {
        _requireOwned(tokenId);
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "not owner or operator");
    }
}
