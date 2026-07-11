// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Daski-local companion to the canonical ERC-8004 IdentityRegistry:
///         a verified wallet→agentId reverse index plus gasless onboarding.
///         See {AgentIndex} for the trust model.
interface IAgentIndex {
    event AgentRegistered(uint256 indexed agentId, address indexed wallet, string agentURI);
    event AgentClaimed(uint256 indexed agentId, address indexed wallet);
    event AgentUnbound(address indexed wallet, uint256 indexed agentId);

    /// @notice Gasless registration: mints a canonical ERC-8004 agent for
    ///         `wallet` (relayer pays gas), transfers the NFT to `wallet`,
    ///         and records the wallet→agentId binding. Requires `wallet`'s
    ///         EIP-712 RegisterAgent consent signature.
    function registerWithSig(string calldata agentURI, address wallet, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 agentId);

    /// @notice Bind the caller to an agent it already controls on the
    ///         canonical registry (owner or verified agentWallet). The path
    ///         for bring-your-own canonical agents and post-transfer rebinds.
    function claim(uint256 agentId) external;

    /// @notice Remove the caller's binding.
    function unbind() external;

    /// @notice Resolve a wallet to its bound agentId, re-verified against the
    ///         canonical registry: returns 0 unless `wallet` is currently the
    ///         agent's ERC-721 owner or its verified agentWallet. A stale
    ///         binding (agent transferred away / wallet rotated out) resolves
    ///         to 0 instead of misattributing.
    function resolve(address wallet) external view returns (uint256 agentId);

    /// @notice Next registerWithSig nonce for `wallet`; signers must embed it
    ///         in the EIP-712 message.
    function registrationNonce(address wallet) external view returns (uint256);

    /// @notice The canonical ERC-8004 IdentityRegistry this index verifies
    ///         against.
    function getIdentityRegistry() external view returns (address);
}
