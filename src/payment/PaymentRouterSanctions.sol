// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentRouterStorage} from "./PaymentRouterStorage.sol";

/// @notice Participant screening shared by router payment and refund paths.
abstract contract PaymentRouterSanctions is PaymentRouterStorage {
    function _requireSettlementParticipantsAllowed(
        address buyerWallet,
        address buyerOwner,
        address buyerAgentWallet,
        address providerOwner,
        address providerWallet,
        address payee,
        uint256 commission
    ) internal view {
        _requireNotSanctioned(buyerWallet);
        _requireNotSanctioned(buyerOwner);
        _requireNotSanctioned(buyerAgentWallet);
        _requireNotSanctioned(providerOwner);
        _requireNotSanctioned(providerWallet);
        _requireNotSanctioned(payee);
        if (commission > 0) _requireNotSanctioned(treasury);
    }

    function _requireRefundParticipantsAllowed(uint256 providerAgentId, address caller, address destination)
        internal
        view
    {
        _requireNotSanctioned(caller);
        _requireNotSanctioned(identity.ownerOf(providerAgentId));
        _requireNotSanctioned(identity.getAgentWallet(providerAgentId));
        _requireNotSanctioned(destination);
    }
}
