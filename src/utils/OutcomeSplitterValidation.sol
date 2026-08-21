// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared deployability checks for immutable outcome splitters.
library OutcomeSplitterValidation {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    error InvalidChain();
    error InvalidToken();
    error InvalidRecipient();
    error InvalidCommission();
    error InvalidListing();

    function validate(
        uint256 canonicalChainId,
        address canonicalToken,
        address providerPayee,
        address daskiCommissionReceiver,
        uint16 commissionBps,
        bytes32 policyVersionHash,
        bytes32 outcomeIdHash,
        bytes32 listingCommitmentHash,
        uint64 listingEpoch,
        address splitter
    ) internal view {
        if (canonicalChainId != block.chainid) revert InvalidChain();
        if (canonicalToken == address(0) || canonicalToken.code.length == 0) revert InvalidToken();
        if (
            providerPayee == address(0) || daskiCommissionReceiver == address(0)
                || providerPayee == daskiCommissionReceiver || providerPayee == splitter
                || daskiCommissionReceiver == splitter || canonicalToken == providerPayee
                || canonicalToken == daskiCommissionReceiver
        ) revert InvalidRecipient();
        if (commissionBps == 0 || commissionBps >= BPS_DENOMINATOR) revert InvalidCommission();
        if (
            policyVersionHash == bytes32(0) || outcomeIdHash == bytes32(0) || listingCommitmentHash == bytes32(0)
                || listingEpoch == 0
        ) revert InvalidListing();
    }
}
