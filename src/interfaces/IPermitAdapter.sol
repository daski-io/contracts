// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Adapter that settles payments via EIP-2612 `permit` + safe
///         transferFrom. Buyer is `msg.sender`. Gasless for the buyer is
///         not a goal here — the buyer pays gas, but avoids a separate
///         `approve` tx by carrying the permit signature in the same call.
interface IPermitAdapter {
    struct PermitData {
        uint256 value; // allowance value to grant (must be >= amount)
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        PermitData calldata permit
    ) external returns (uint256 paymentId);
}
