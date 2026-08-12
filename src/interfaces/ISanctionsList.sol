// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainalysis-compatible on-chain sanctions list.
interface ISanctionsList {
    function isSanctioned(address account) external view returns (bool);
}
