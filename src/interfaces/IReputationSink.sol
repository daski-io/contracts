// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Retryable reputation sink used by PaymentRouter. Token settlement
///         never depends on sink availability; failed writes can be replayed
///         through PaymentRouter.syncReputation.
interface IReputationSink {
    function paymentRouter() external view returns (address);
    function isConfigured() external view returns (bool);
    function recordPayment(uint256 paymentId) external;
    function recordRefund(uint256 paymentId, uint256 amountToBuyer) external;
}
