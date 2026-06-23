// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal reputation sink. Decoupled from the PaymentRouter: the
///         admin may wire this on or leave it unset, and a failed reputation
///         call never reverts a refund (reputation is a tracking sidecar, not
///         consensus). Implemented by ReputationStorage.
interface IReputationRefundSink {
    function recordRefund(uint256 paymentId, uint256 amountToBuyer) external;
}
