// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEAS, ISchemaRegistry} from "../src/interfaces/IEAS.sol";

/// @notice Restricts reputation deployments to the canonical EAS contracts.
abstract contract ReputationEASIdentity {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address private constant BASE_EAS = 0x4200000000000000000000000000000000000021;
    address private constant BASE_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    error UnsupportedEASChain(uint256 chainId);
    error UnexpectedEAS(address expected, address actual);
    error UnexpectedSchemaRegistry(address expected, address actual);
    error ExternalDependencyHasNoCode(address dependency);

    function canonicalEAS(uint256 chainId) public pure returns (address) {
        if (chainId == BASE_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_EAS;
        return address(0);
    }

    function canonicalSchemaRegistry(uint256 chainId) public pure returns (address) {
        if (chainId == BASE_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SCHEMA_REGISTRY;
        return address(0);
    }

    function _validateEAS(address easAddress) internal view returns (ISchemaRegistry registry) {
        address expectedEAS = canonicalEAS(block.chainid);
        if (expectedEAS == address(0)) revert UnsupportedEASChain(block.chainid);
        if (easAddress != expectedEAS) revert UnexpectedEAS(expectedEAS, easAddress);
        if (easAddress.code.length == 0) revert ExternalDependencyHasNoCode(easAddress);

        registry = IEAS(easAddress).getSchemaRegistry();
        address registryAddress = address(registry);
        address expectedRegistry = canonicalSchemaRegistry(block.chainid);
        if (registryAddress != expectedRegistry) {
            revert UnexpectedSchemaRegistry(expectedRegistry, registryAddress);
        }
        if (registryAddress.code.length == 0) revert ExternalDependencyHasNoCode(registryAddress);
    }
}
