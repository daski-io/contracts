// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ERC-8004 Identity Registry
// Pinned to draft spec commit 503591a6e80e6e1affdd6403341e25269141f046
// (ethereum/ERCs, merged 2026-01-25, "Updates from community feedback").
// Source: https://github.com/ethereum/ERCs/blob/503591a6/ERCS/erc-8004.md

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721URIStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @notice ERC-8004-compliant Identity Registry built on ERC-721 with URIStorage.
///
/// Each ERC-8004 agent NFT registered here represents a **provider** (a
/// real-world operator that fields one or more services on Daski). Services
/// themselves are managed in the Daski `ServiceRegistry` and are **NOT**
/// ERC-8004 agents. The provider's A2A Agent Card (resolved via `agentURI`)
/// exposes services as A2A `AgentSkill` entries. Do not re-introduce the
/// per-service-NFT pattern — it fragments operator reputation and breaks A2A
/// skill discovery.
///
/// Design notes:
///   * Every agent owns a unique agentId (ERC-721 tokenId). agentURI (tokenURI)
///     resolves to the agent registration JSON file per §Identity Registry.
///   * The reserved metadata key "agentWallet" stores the wallet that receives
///     payments. Per spec, it is initially the agent owner and can be rotated
///     only via setAgentWallet() with a valid EIP-712 / ERC-1271 signature.
///   * On token transfer the agentWallet is auto-cleared; the new owner must
///     re-verify via setAgentWallet().
///
/// Daski extension:
///   * agentOfWallet(address) returns the agentId currently mapped to a given
///     wallet. Spec §Reputation Registry suggests agents use `agentWallet` as
///     their clientAddress for aggregation, which this mapping accelerates.
///     PaymentRouter uses it to resolve the buyer's agentId from the EIP-3009
///     signer. This is a non-spec auxiliary index; it is kept in sync with the
///     authoritative per-agent _agentWallet mapping and does not change
///     spec-defined behavior.
contract IdentityRegistry is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    IIdentityRegistry
{
    /// @notice Reserved metadata key for the agent's payment wallet. Cannot
    ///         be set via setMetadata() or the register metadata array.
    string internal constant AGENT_WALLET_KEY = "agentWallet";

    /// @dev EIP-712 struct hash for agent wallet rotation. Hashed over the
    ///      registry's domain separator (name = "Daski IdentityRegistry",
    ///      version = "1", chainId, verifyingContract). The nonce is per
    ///      `newWallet` and increments on every successful setAgentWallet —
    ///      prevents replay if the wallet is mapped, unset, then someone
    ///      tries to re-bind it within the original deadline.
    bytes32 public constant SET_AGENT_WALLET_TYPEHASH =
        keccak256("SetAgentWallet(uint256 agentId,address newWallet,uint256 nonce,uint256 deadline)");

    /// @dev EIP-712 struct hash for gasless agent registration. Same domain
    ///      separator as SET_AGENT_WALLET_TYPEHASH. The nonce is per-wallet
    ///      and increments on every successful registerBySig — protects
    ///      against replay if the wallet is registered, transferred (which
    ///      clears the agentWallet reverse index), and then re-registered.
    bytes32 public constant REGISTER_AGENT_TYPEHASH =
        keccak256("RegisterAgent(string agentURI,address agentWallet,uint256 nonce,uint256 deadline)");

    address public admin;
    address public pendingAdmin;
    uint256 private _nextAgentId;

    // agentId → (metadataKey → bytes). `agentWallet` is stored separately
    // for cheap reads; setMetadata rejects that key.
    mapping(uint256 => mapping(string => bytes)) private _metadata;
    mapping(uint256 => address) private _agentWallet;

    // Reverse index: wallet → agentId. Zero means unmapped. Enforced 1:1 in
    // both directions — registration paths reject a wallet that already has
    // an active mapping.
    mapping(address => uint256) private _agentOfWallet;

    // Per-wallet registration nonce. Bumps once per successful registerBySig.
    mapping(address => uint256) private _registrationNonces;

    // Per-wallet wallet-rotation nonce. Bumps on every setAgentWallet so the
    // typed-data signature cannot be replayed after unsetAgentWallet.
    mapping(address => uint256) private _walletRotationNonces;

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _admin) external initializer {
        require(_admin != address(0), "zero admin");
        __ERC721_init("Daski Identity", "DASKI-ID");
        __ERC721URIStorage_init();
        __EIP712_init("Daski IdentityRegistry", "1");
        admin = _admin;
        _nextAgentId = 1;
    }

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

    /// @notice Gasless registration: anyone (typically a relayer) can submit
    ///         this on behalf of `agentWallet` if `agentWallet` signed an
    ///         EIP-712 RegisterAgent struct. The minted NFT goes to
    ///         `agentWallet`, not msg.sender. Reverts if the wallet is
    ///         already registered.
    /// @dev Uses SignatureChecker so EOAs (ECDSA) and ERC-1271 contract
    ///      wallets are both supported. Per-wallet nonce prevents replay
    ///      across registration / transfer / re-registration cycles.
    function registerBySig(string calldata agentURI, address agentWallet, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 agentId)
    {
        require(block.timestamp <= deadline, "signature expired");
        require(agentWallet != address(0), "zero wallet");
        require(_agentOfWallet[agentWallet] == 0, "wallet already registered");

        uint256 nonce = _registrationNonces[agentWallet];
        bytes32 structHash =
            keccak256(abi.encode(REGISTER_AGENT_TYPEHASH, keccak256(bytes(agentURI)), agentWallet, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        require(SignatureChecker.isValidSignatureNow(agentWallet, digest, signature), "invalid signature");

        // Bump the nonce BEFORE minting so any reentrant code (e.g. an
        // ERC721Receiver hook) sees the post-state.
        _registrationNonces[agentWallet] = nonce + 1;
        agentId = _register(agentWallet, agentURI);
    }

    /// @notice Returns the next registerBySig nonce for `wallet`. Clients
    ///         that build the EIP-712 message must read this and embed it.
    function registrationNonce(address wallet) external view returns (uint256) {
        return _registrationNonces[wallet];
    }

    function _register(address owner, string memory agentURI) internal returns (uint256 agentId) {
        // Enforce 1:1 wallet→agent. Without this, a wallet that already owns
        // agentX could mint agentY and silently overwrite the reverse index,
        // leaving agentX with `_agentWallet` set but `agentOfWallet` pointing
        // at agentY. Refund auth and EAS reputation auth both rely on the
        // reverse index, so the orphaned mappings would brick agentX.
        require(_agentOfWallet[owner] == 0, "wallet already has an agent");

        agentId = _nextAgentId++;

        // Set the reverse index BEFORE _safeMint so any onERC721Received hook
        // sees the post-state and reentrant attempts to register a second
        // agent for the same wallet revert at the require above.
        _writeAgentWallet(agentId, owner);

        _safeMint(owner, agentId);
        if (bytes(agentURI).length > 0) {
            _setTokenURI(agentId, agentURI);
        }

        // Spec: "the key `agentWallet` [...] is initially set to the owner's
        // address" — emit the MetadataSet event alongside the Transfer event
        // produced by _safeMint.
        bytes memory ownerBytes = abi.encodePacked(owner);
        emit MetadataSet(agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, ownerBytes);

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
    // Metadata (generic key/value, excludes reserved "agentWallet")
    // ------------------------------------------------------------------

    function getMetadata(uint256 agentId, string memory metadataKey) external view override returns (bytes memory) {
        _requireMinted(agentId);
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
    // Agent wallet rotation (EIP-712 / ERC-1271 signature required)
    // ------------------------------------------------------------------

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature)
        external
        override
    {
        _requireOwnerOrApproved(agentId);
        require(block.timestamp <= deadline, "signature expired");
        require(newWallet != address(0), "zero wallet");
        require(_agentOfWallet[newWallet] == 0, "wallet already mapped");

        // Per-wallet nonce binds this signature to a specific call instance.
        // Without it, an old signature could be replayed after unsetAgentWallet
        // to re-bind the wallet without the wallet owner's renewed consent.
        uint256 nonce = _walletRotationNonces[newWallet];
        bytes32 structHash = keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        // SignatureChecker handles both EOA ECDSA and ERC-1271 contract signatures.
        require(SignatureChecker.isValidSignatureNow(newWallet, digest, signature), "invalid wallet signature");

        // Bump the nonce BEFORE mutating wallet state — same reentrancy
        // discipline as registerBySig.
        _walletRotationNonces[newWallet] = nonce + 1;

        _writeAgentWallet(agentId, newWallet);
        bytes memory walletBytes = abi.encodePacked(newWallet);
        emit MetadataSet(agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, walletBytes);
    }

    /// @notice Returns the next setAgentWallet nonce for `wallet`. Clients
    ///         building the EIP-712 message must read this and embed it.
    function walletRotationNonce(address wallet) external view returns (uint256) {
        return _walletRotationNonces[wallet];
    }

    function getAgentWallet(uint256 agentId) external view override returns (address) {
        _requireMinted(agentId);
        return _agentWallet[agentId];
    }

    function unsetAgentWallet(uint256 agentId) external override {
        _requireOwnerOrApproved(agentId);
        _clearAgentWallet(agentId);
        emit MetadataSet(agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, bytes(""));
    }

    // ------------------------------------------------------------------
    // Daski extension — reverse index
    // ------------------------------------------------------------------

    /// @notice Returns the agentId currently mapped to `wallet`, or zero if
    ///         no agent claims it. Reflects the current `agentWallet`
    ///         metadata and is cleared on transfer or unsetAgentWallet.
    function agentOfWallet(address wallet) external view returns (uint256) {
        return _agentOfWallet[wallet];
    }

    // ------------------------------------------------------------------
    // ERC-721 hooks: auto-clear agentWallet on transfer
    // ------------------------------------------------------------------

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && from != to && _exists(tokenId)) {
            // Spec: "When the agent is transferred, `agentWallet` is
            // automatically cleared [...] and must be re-verified by the new owner."
            _clearAgentWallet(tokenId);
            emit MetadataSet(tokenId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, bytes(""));
        }
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _writeAgentWallet(uint256 agentId, address wallet) internal {
        address prev = _agentWallet[agentId];
        if (prev != address(0)) {
            delete _agentOfWallet[prev];
        }
        _agentWallet[agentId] = wallet;
        _agentOfWallet[wallet] = agentId;
    }

    function _clearAgentWallet(uint256 agentId) internal {
        address prev = _agentWallet[agentId];
        if (prev != address(0)) {
            delete _agentOfWallet[prev];
        }
        delete _agentWallet[agentId];
    }

    function _requireMinted(uint256 tokenId) internal view {
        require(_ownerOf(tokenId) != address(0), "agent not registered");
    }

    function _requireOwnerOrApproved(uint256 tokenId) internal view {
        _requireMinted(tokenId);
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "not owner or operator");
    }

    // ------------------------------------------------------------------
    // Required overrides for multiple inheritance
    // ------------------------------------------------------------------

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------
    // Admin / upgrade
    // ------------------------------------------------------------------

    /// @notice Step 1 of admin transfer — propose a new admin. Step 2 is
    ///         `acceptAdmin()` from `newAdmin`. A typo at proposal time is
    ///         recoverable; a typo at acceptance is not, but acceptance can
    ///         only be done by the holder of the proposed key.
    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
