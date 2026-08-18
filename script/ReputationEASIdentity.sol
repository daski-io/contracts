// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IEAS, ISchemaRegistry} from "../src/interfaces/IEAS.sol";

/// @notice Reviewed EAS proxy and implementation identities for supported chains.
abstract contract ReputationEASIdentity is Script {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address private constant BASE_EAS = 0x4200000000000000000000000000000000000021;
    address private constant BASE_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant BASE_PROXY_RUNTIME_HASH =
        0x1f958654ab06a152993e7a0ae7b6dbb0d4b19265cc9337b8789fe1353bd9dc35;
    address private constant BASE_EAS_IMPLEMENTATION = 0xbEb5Fc579115071764c7423A4f12eDde41f106Ed;
    bytes32 private constant BASE_EAS_IMPLEMENTATION_HASH =
        0x16b293cd7ed66fa1e03076e5847c59b146a83c187d991c42fe6056b3c1cc0513;
    address private constant BASE_SCHEMA_IMPLEMENTATION = 0x75505a97BD334E7BD3C476893285569C4136Fa0F;
    bytes32 private constant BASE_SCHEMA_IMPLEMENTATION_HASH =
        0x020abfe7296543ec2d825b97a9c3fe26d7beea1fbf80de58e0da20e2a6825753;
    bytes32 private constant BASE_SEPOLIA_PROXY_RUNTIME_HASH =
        0xfa8c9db6c6cab7108dea276f4cd09d575674eb0852c0fa3187e59e98ef977998;
    address private constant BASE_SEPOLIA_EAS_IMPLEMENTATION = 0xC0D3c0D3C0d3c0D3c0D3C0D3c0D3c0d3c0d30021;
    bytes32 private constant BASE_SEPOLIA_EAS_IMPLEMENTATION_HASH =
        0x703f246f804f8d4b315fd7b5fc504671f726230373571e02b69794d0f2614fd7;
    address private constant BASE_SEPOLIA_SCHEMA_IMPLEMENTATION = 0xc0d3c0d3c0d3C0d3c0d3C0D3C0D3c0d3C0D30020;
    bytes32 private constant BASE_SEPOLIA_SCHEMA_IMPLEMENTATION_HASH =
        0x4f01862031e523fc22a2bbe86c670a2f57f0da57ce1f582b0776042290377672;

    error UnsupportedEASChain(uint256 chainId);
    error UnexpectedEAS(address expected, address actual);
    error UnexpectedSchemaRegistry(address expected, address actual);
    error ExternalDependencyHasNoCode(address dependency);
    error UnexpectedRuntimeCodeHash(address dependency, bytes32 expected, bytes32 actual);
    error UnexpectedImplementation(address proxy, address expected, address actual);

    function canonicalEAS(uint256 chainId) public pure returns (address) {
        if (chainId == BASE_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_EAS;
        return address(0);
    }

    function canonicalSchemaRegistry(uint256 chainId) public pure returns (address) {
        if (chainId == BASE_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SCHEMA_REGISTRY;
        return address(0);
    }

    function reviewedEASDeployment(uint256 chainId)
        public
        pure
        virtual
        returns (
            bytes32 proxyRuntimeHash,
            address easImplementation,
            bytes32 easImplementationHash,
            address schemaImplementation,
            bytes32 schemaImplementationHash
        )
    {
        if (chainId == BASE_CHAIN_ID) {
            return (
                BASE_PROXY_RUNTIME_HASH,
                BASE_EAS_IMPLEMENTATION,
                BASE_EAS_IMPLEMENTATION_HASH,
                BASE_SCHEMA_IMPLEMENTATION,
                BASE_SCHEMA_IMPLEMENTATION_HASH
            );
        }
        if (chainId == BASE_SEPOLIA_CHAIN_ID) {
            return (
                BASE_SEPOLIA_PROXY_RUNTIME_HASH,
                BASE_SEPOLIA_EAS_IMPLEMENTATION,
                BASE_SEPOLIA_EAS_IMPLEMENTATION_HASH,
                BASE_SEPOLIA_SCHEMA_IMPLEMENTATION,
                BASE_SEPOLIA_SCHEMA_IMPLEMENTATION_HASH
            );
        }
    }

    function _validateEAS(address easAddress, bool allowNonCanonicalEAS)
        internal
        view
        returns (ISchemaRegistry registry)
    {
        address expectedEAS = canonicalEAS(block.chainid);
        if (expectedEAS == address(0)) {
            if (!allowNonCanonicalEAS) revert UnsupportedEASChain(block.chainid);
        } else if (easAddress != expectedEAS) {
            revert UnexpectedEAS(expectedEAS, easAddress);
        }
        if (easAddress.code.length == 0) revert ExternalDependencyHasNoCode(easAddress);

        (
            bytes32 proxyRuntimeHash,
            address easImplementation,
            bytes32 easImplementationHash,
            address schemaImplementation,
            bytes32 schemaImplementationHash
        ) = reviewedEASDeployment(block.chainid);
        if (proxyRuntimeHash != bytes32(0)) {
            _requireReviewedProxy(easAddress, proxyRuntimeHash, easImplementation, easImplementationHash);
        }

        registry = IEAS(easAddress).getSchemaRegistry();
        address registryAddress = address(registry);
        if (registryAddress.code.length == 0) revert ExternalDependencyHasNoCode(registryAddress);
        address expectedRegistry = canonicalSchemaRegistry(block.chainid);
        if (expectedRegistry != address(0) && registryAddress != expectedRegistry) {
            revert UnexpectedSchemaRegistry(expectedRegistry, registryAddress);
        }
        if (proxyRuntimeHash != bytes32(0)) {
            _requireReviewedProxy(registryAddress, proxyRuntimeHash, schemaImplementation, schemaImplementationHash);
        }
    }

    function _requireReviewedProxy(
        address proxy,
        bytes32 expectedProxyHash,
        address expectedImplementation,
        bytes32 expectedImplementationHash
    ) private view {
        if (proxy.codehash != expectedProxyHash) {
            revert UnexpectedRuntimeCodeHash(proxy, expectedProxyHash, proxy.codehash);
        }
        // EIP-1967 stores the implementation address in the low 20 bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        address implementation = address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
        if (implementation != expectedImplementation) {
            revert UnexpectedImplementation(proxy, expectedImplementation, implementation);
        }
        if (implementation.codehash != expectedImplementationHash) {
            revert UnexpectedRuntimeCodeHash(implementation, expectedImplementationHash, implementation.codehash);
        }
    }
}
