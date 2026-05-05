// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Adapter that settles x402 (EIP-3009 TransferWithAuthorization)
///         payments. Funds move directly from buyer to the router via the
///         token's `transferWithAuthorization`; adapter never holds funds.
interface IX402Adapter {
    struct EIP3009Auth {
        address from;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        EIP3009Auth calldata auth
    ) external returns (uint256 paymentId);
}
