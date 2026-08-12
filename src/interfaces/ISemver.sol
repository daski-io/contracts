// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Semantic-version surface required of EAS ecosystem contracts.
///
/// Mirrors the canonical EAS ISemver (eas-contracts/contracts/ISemver.sol).
interface ISemver {
    /// @notice Returns the full semver contract version.
    function version() external view returns (string memory);
}
