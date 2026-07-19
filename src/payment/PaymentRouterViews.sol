// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentRouterStorage} from "./PaymentRouterStorage.sol";

/// @notice Read-only access to router accounting and configuration.
abstract contract PaymentRouterViews is PaymentRouterStorage {
    function quoteCommission(uint256 amount) external view returns (uint256 commission, uint256 providerAmount) {
        commission = (amount * commissionBps) / 10000;
        providerAmount = amount - commission;
    }

    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory) {
        require(_payments[paymentId].amount > 0, "payment not found");
        return _payments[paymentId];
    }

    function refundedAmount(uint256 paymentId) external view returns (uint256) {
        return _refundedAmount[paymentId];
    }

    function serviceRefUsed(bytes32 serviceRef) external view returns (bool) {
        return _usedServiceRefs[serviceRef];
    }

    function isAdapter(address adapter) external view returns (bool) {
        return adapters[adapter];
    }

    function isAcceptedToken(address token) external view returns (bool) {
        return acceptedTokens[token];
    }
}
