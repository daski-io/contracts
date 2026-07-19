// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Atomic reputation mirror used by PaymentRouter. When configured,
///         settlement and refund records must succeed together with their
///         corresponding token movement.
interface IReputationSink {
    function isConfigured() external view returns (bool);
    function recordPayment(uint256 paymentId) external;
    function recordRefund(uint256 paymentId, uint256 amountToBuyer) external;
}
