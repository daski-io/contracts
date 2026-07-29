// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICanonicalIdentity} from "../interfaces/ICanonicalIdentity.sol";

/// @notice Settlement-time checks for buyer/provider control overlap.
library LibReputationEligibility {
    struct Party {
        uint256 agentId;
        address owner;
        address[3] participants;
    }

    function hasProvableControlOverlap(ICanonicalIdentity identity, Party memory buyer, Party memory provider)
        internal
        view
        returns (bool)
    {
        address buyerApproved = identity.getApproved(buyer.agentId);
        address providerApproved = identity.getApproved(provider.agentId);
        address[4] memory buyerControllers =
            [buyer.participants[0], buyer.participants[1], buyer.participants[2], buyerApproved];
        address[4] memory providerControllers =
            [provider.participants[0], provider.participants[1], provider.participants[2], providerApproved];

        if (_hasDirectOverlap(buyerControllers, providerControllers)) return true;
        if (_hasOperatorControl(identity, provider.owner, buyerControllers)) return true;
        return _hasOperatorControl(identity, buyer.owner, providerControllers);
    }

    function _hasDirectOverlap(address[4] memory left, address[4] memory right) private pure returns (bool) {
        for (uint256 i = 0; i < left.length; i++) {
            if (left[i] == address(0)) continue;
            for (uint256 j = 0; j < right.length; j++) {
                if (left[i] == right[j]) return true;
            }
        }
        return false;
    }

    function _hasOperatorControl(ICanonicalIdentity identity, address owner, address[4] memory controllers)
        private
        view
        returns (bool)
    {
        for (uint256 i = 0; i < controllers.length; i++) {
            address controller = controllers[i];
            if (controller != address(0) && identity.isApprovedForAll(owner, controller)) return true;
        }
        return false;
    }
}
