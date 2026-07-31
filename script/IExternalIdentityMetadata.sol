// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExternalIdentityMetadata {
    function owner() external view returns (address);
    function getVersion() external view returns (string memory);
}
