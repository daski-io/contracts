// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICanonicalIdentity} from "../interfaces/ICanonicalIdentity.sol";

/// @notice Settlement-time checks for buyer/provider control overlap.
library LibReputationEligibility {
    function hasProvableControlOverlap(
        ICanonicalIdentity identity,
        uint256 providerAgentId,
        address[3] memory buyerAddresses,
        address[3] memory providerAddresses
    ) internal view returns (bool) {
        address approved = identity.getApproved(providerAgentId);
        for (uint256 i = 0; i < buyerAddresses.length; i++) {
            address buyerAddress = buyerAddresses[i];
            // Unset agentWallet and absent ERC-721 approval both read as zero;
            // treating those values as shared control would reject normal buyers.
            if (buyerAddress == address(0)) continue;

            for (uint256 j = 0; j < providerAddresses.length; j++) {
                address providerAddress = providerAddresses[j];
                if (providerAddress != address(0) && buyerAddress == providerAddress) return true;
            }

            if (buyerAddress == approved || identity.isApprovedForAll(providerAddresses[0], buyerAddress)) {
                return true;
            }
        }
        return false;
    }
}
