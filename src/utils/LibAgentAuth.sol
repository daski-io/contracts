// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Shared auth check for "caller has agent-owner-equivalent rights":
///         NFT owner, OR ERC-721 operator (isApprovedForAll), OR per-token
///         approved spender (getApproved). Used by ServiceRegistry,
///         ProviderRegistry, ReputationRegistry (`appendResponse`), and
///         ValidationRegistry (`validationRequest`).
///
/// Not used by PaymentRouter.refund — that path adds a fourth branch
/// (`agentOfWallet`) and stays inline.
library LibAgentAuth {
    function isAgentAuthorized(IERC721 nft, uint256 agentId, address caller) internal view returns (bool) {
        address owner = nft.ownerOf(agentId);
        return caller == owner || nft.isApprovedForAll(owner, caller) || nft.getApproved(agentId) == caller;
    }

    function requireAgentAuth(IERC721 nft, uint256 agentId, address caller) internal view {
        require(isAgentAuthorized(nft, agentId, caller), "not owner or operator");
    }
}
