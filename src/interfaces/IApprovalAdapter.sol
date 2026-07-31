// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Simplest adapter: buyer pre-approves the adapter contract for
///         `amount` of `token`, then calls `settle`. Adapter pulls the funds
///         into the router and invokes `router.settle(...)`. Buyer pays gas.
interface IApprovalAdapter {
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee
    ) external returns (uint256 paymentId);
}
