// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice EIP-3009 authorization surface used by X402Adapter and its tests.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
