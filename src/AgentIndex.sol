// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ICanonicalIdentity} from "./interfaces/ICanonicalIdentity.sol";
import {IAgentIndex} from "./interfaces/IAgentIndex.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";

/// @notice Daski-local companion to the canonical ERC-8004 IdentityRegistry
///         (the 0x8004A... per-chain singleton). Daski no longer deploys an
///         identity registry of its own; agents live in the canonical one.
///         This contract fills the two gaps the canonical registry leaves
///         open:
///
///         1. Reverse lookup. The canonical registry exposes
///            getAgentWallet(agentId) but no wallet→agentId index. Payment
///            adapters must resolve "which agent is this payer?" in one call,
///            so this contract maintains that index — as a HINT re-verified
///            against the canonical registry on every read (`resolve`). A
///            stale binding (NFT transferred away, wallet rotated out)
///            resolves to zero rather than misattributing payments or
///            reputation.
///
///         2. Gasless onboarding. The canonical registry has no registerBySig.
///            `registerWithSig` lets a relayer (the Daski gateway facilitator,
///            or an adapter mid-settlement) mint a canonical agent for a fresh
///            buyer wallet that holds USDC but no ETH: this contract registers
///            on the canonical registry (minting to itself), transfers the NFT
///            to the wallet, and records the binding — one tx, gated on the
///            wallet's EIP-712 consent signature.
///
/// One wallet maps to at most one agentId here (Daski's 1:1 attribution
/// policy). The canonical registry itself lets a wallet own many agents;
/// wallets that bring their own canonical agent pick which one Daski should
/// attribute via `claim`.
///
/// The canonical registry does NOT auto-set `agentWallet` at registration,
/// and clears it on every transfer — so for agents minted here the buyer
/// wallet's control is proven by ERC-721 ownership, not agentWallet.
/// `resolve` accepts either.
contract AgentIndex is Admin2StepUpgradeable, EIP712Upgradeable, IERC721Receiver, IAgentIndex {
    /// @dev EIP-712 struct hash for gasless registration consent. The struct
    ///      layout is kept identical to the retired Daski IdentityRegistry's
    ///      RegisterAgent, so off-chain signers only swap the domain
    ///      (name = "Daski AgentIndex", verifyingContract = this proxy). The
    ///      nonce is per-wallet and bumps on every successful registerWithSig
    ///      — a consumed consent can never be replayed, even after the wallet
    ///      transfers the NFT away and registers afresh.
    bytes32 public constant REGISTER_AGENT_TYPEHASH =
        keccak256("RegisterAgent(string agentURI,address agentWallet,uint256 nonce,uint256 deadline)");

    ICanonicalIdentity public identity;

    mapping(address => uint256) private _agentIdOf;
    mapping(address => uint256) private _registrationNonces;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identity, address _admin) external initializer {
        require(_identity != address(0), "zero identity");
        __Admin2Step_init(_admin);
        __EIP712_init("Daski AgentIndex", "1");
        identity = ICanonicalIdentity(_identity);
    }

    // ------------------------------------------------------------------
    // Gasless registration
    // ------------------------------------------------------------------

    /// @inheritdoc IAgentIndex
    function registerWithSig(string calldata agentURI, address wallet, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 agentId)
    {
        require(block.timestamp <= deadline, "signature expired");
        require(wallet != address(0), "zero wallet");
        // Live check, not a raw index read — a stale binding (agent moved or
        // rotated away) must not block the wallet from registering afresh.
        require(_resolve(wallet) == 0, "wallet already has an agent");

        uint256 nonce = _registrationNonces[wallet];
        bytes32 structHash =
            keccak256(abi.encode(REGISTER_AGENT_TYPEHASH, keccak256(bytes(agentURI)), wallet, nonce, deadline));

        // SignatureChecker supports both EOA ECDSA and ERC-1271 contract wallets.
        require(
            SignatureChecker.isValidSignatureNow(wallet, _hashTypedDataV4(structHash), signature), "invalid signature"
        );

        // Bump before any external call so reentrant paths see the post-state.
        _registrationNonces[wallet] = nonce + 1;

        // Mint on the canonical registry (to this contract), record the
        // binding, hand the NFT to the wallet. Index-before-transfer so an
        // onERC721Received callback on a contract wallet observes a
        // consistent binding; a reentrant registerWithSig for the same wallet
        // fails both the live check and the bumped nonce.
        agentId = identity.register(agentURI);
        _agentIdOf[wallet] = agentId;
        identity.safeTransferFrom(address(this), wallet, agentId);

        emit AgentRegistered(agentId, wallet, agentURI);
    }

    // ------------------------------------------------------------------
    // Bind / unbind existing canonical agents
    // ------------------------------------------------------------------

    /// @inheritdoc IAgentIndex
    function claim(uint256 agentId) external {
        require(_controlsAgent(agentId, msg.sender), "not agent owner or wallet");
        _agentIdOf[msg.sender] = agentId;
        emit AgentClaimed(agentId, msg.sender);
    }

    /// @inheritdoc IAgentIndex
    function unbind() external {
        uint256 agentId = _agentIdOf[msg.sender];
        require(agentId != 0, "nothing bound");
        delete _agentIdOf[msg.sender];
        emit AgentUnbound(msg.sender, agentId);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IAgentIndex
    function resolve(address wallet) external view returns (uint256) {
        return _resolve(wallet);
    }

    /// @inheritdoc IAgentIndex
    function registrationNonce(address wallet) external view returns (uint256) {
        return _registrationNonces[wallet];
    }

    /// @inheritdoc IAgentIndex
    function getIdentityRegistry() external view returns (address) {
        return address(identity);
    }

    /// @notice Accepts only mid-registration mints from the canonical
    ///         registry; stray NFTs are rejected so they can't get stuck.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(identity), "unexpected token");
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _resolve(address wallet) internal view returns (uint256 agentId) {
        agentId = _agentIdOf[wallet];
        if (agentId == 0) return 0;
        if (!_controlsAgent(agentId, wallet)) return 0;
    }

    /// @dev "Controls" = current ERC-721 owner OR current verified
    ///      agentWallet on the canonical registry. ownerOf/getAgentWallet
    ///      revert for burned or never-minted ids — treated as "does not
    ///      control" rather than bubbling a revert into payment paths.
    function _controlsAgent(uint256 agentId, address who) internal view returns (bool) {
        try identity.ownerOf(agentId) returns (address owner) {
            if (owner == who) return true;
        } catch {
            return false;
        }
        try identity.getAgentWallet(agentId) returns (address wallet_) {
            return wallet_ == who;
        } catch {
            return false;
        }
    }

    uint256[50] private __gap;
}
