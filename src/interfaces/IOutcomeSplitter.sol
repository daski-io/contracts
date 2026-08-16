// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOutcomeSplitter {
    event Released(
        bytes32 indexed outcomeIdHash,
        uint64 indexed listingEpoch,
        uint64 indexed sequence,
        bytes32 policyVersionHash,
        bytes32 listingCommitmentHash,
        uint256 grossAmount,
        uint256 providerNetAmount,
        uint256 daskiCommissionAmount
    );

    function canonicalChainId() external view returns (uint256);
    function canonicalToken() external view returns (address);
    function providerPayee() external view returns (address);
    function daskiCommissionReceiver() external view returns (address);
    function commissionBps() external view returns (uint16);
    function policyVersionHash() external view returns (bytes32);
    function outcomeIdHash() external view returns (bytes32);
    function listingCommitmentHash() external view returns (bytes32);
    function listingEpoch() external view returns (uint64);
    function releaseSequence() external view returns (uint64);
    function minimumReleasableBalance() external view returns (uint256);
    function releaseAll() external returns (uint256 grossAmount);
}
