// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ICanonicalIdentity} from "../interfaces/ICanonicalIdentity.sol";

/// @notice Shared auth check for "caller has agent-owner-equivalent rights":
///         NFT owner, OR ERC-721 operator (isApprovedForAll), OR per-token
///         approved spender (getApproved). Used by ServiceRegistry,
///         ProviderRegistry, and ValidationRegistry (`validationRequest`),
///         all reading the canonical ERC-8004 IdentityRegistry.
/// The extended helpers also cover the canonical registry's live
/// `agentWallet` for refund and attestation paths.
library LibAgentAuth {
    function isAgentAuthorized(IERC721 nft, uint256 agentId, address caller) internal view returns (bool) {
        address owner = nft.ownerOf(agentId);
        return caller == owner || nft.isApprovedForAll(owner, caller) || nft.getApproved(agentId) == caller;
    }

    function requireAgentAuth(IERC721 nft, uint256 agentId, address caller) internal view {
        require(isAgentAuthorized(nft, agentId, caller), "not owner or operator");
    }

    function isOwnerOrAgentWallet(ICanonicalIdentity identity, uint256 agentId, address caller)
        internal
        view
        returns (bool)
    {
        return identity.ownerOf(agentId) == caller || identity.getAgentWallet(agentId) == caller;
    }

    function isAuthorizedOrAgentWallet(ICanonicalIdentity identity, uint256 agentId, address caller)
        internal
        view
        returns (bool)
    {
        return isAgentAuthorized(identity, agentId, caller) || identity.getAgentWallet(agentId) == caller;
    }
}
