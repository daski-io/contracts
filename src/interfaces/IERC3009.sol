// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal subset of EIP-3009 used by X402Adapter to pull tokens from
/// a buyer (directly into the PaymentRouter) on behalf of an off-chain
/// facilitator.
interface IERC3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice True once the (authorizer, nonce) authorization has been used.
    ///         Note this records ONLY that some authorization with this nonce
    ///         was consumed — the recipient and value of that transfer are
    ///         not recoverable from this state.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}
