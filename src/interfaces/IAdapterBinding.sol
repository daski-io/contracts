// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Common immutable wiring exposed by Daski payment adapters.
interface IAdapterBinding {
    function router() external view returns (address);
    function agentIndex() external view returns (address);
}
