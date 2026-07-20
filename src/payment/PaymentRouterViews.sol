// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentRouterStorage} from "./PaymentRouterStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Read-only access to router accounting and configuration.
abstract contract PaymentRouterViews is PaymentRouterStorage {
    using EnumerableSet for EnumerableSet.AddressSet;

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

    function reputationSyncState(uint256 paymentId) external view returns (bool paymentSynced, uint256 refundSynced) {
        return (_reputationPaymentSynced[paymentId], _reputationRefundSynced[paymentId]);
    }

    function computePaymentKey(uint256 buyerAgentId, uint256 providerAgentId, bytes32 serviceId, bytes32 serviceRef)
        external
        pure
        returns (bytes32)
    {
        return _paymentKey(buyerAgentId, providerAgentId, serviceId, serviceRef);
    }

    function paymentKeyUsed(bytes32 paymentKey) external view returns (bool) {
        return _usedPaymentKeys[paymentKey];
    }

    function isAdapter(address adapter) external view returns (bool) {
        return _adapters.contains(adapter);
    }

    function getAdapterCount() external view returns (uint256) {
        return _adapters.length();
    }

    function getAdapterAt(uint256 index) external view returns (address) {
        return _adapters.at(index);
    }

    function isAcceptedToken(address token) external view returns (bool) {
        return _acceptedTokens.contains(token);
    }

    function getAcceptedTokenCount() external view returns (uint256) {
        return _acceptedTokens.length();
    }

    function getAcceptedTokenAt(uint256 index) external view returns (address) {
        return _acceptedTokens.at(index);
    }

    function getTokenReputationConfig(address token)
        external
        view
        returns (bool reputationEnabled, uint256 minimumReputationAmount)
    {
        TokenReputationConfig storage config = _tokenReputationConfigs[token];
        return (config.enabled, config.minimumAmount);
    }
}
