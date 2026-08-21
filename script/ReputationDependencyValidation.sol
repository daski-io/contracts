// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "../src/interfaces/IServiceRegistry.sol";

interface IReputationProviderDependencies {
    function identity() external view returns (address);
    function usdc() external view returns (address);
    function sanctionsOracle() external view returns (address);
}

interface IReputationServiceDependencies {
    function identity() external view returns (address);
    function providerRegistry() external view returns (address);
    function sanctionsOracle() external view returns (address);
}

/// @notice Verifies that reputation dependencies are deployed and consistently wired.
abstract contract ReputationDependencyValidation {
    function _validateDependencies(
        address identityRegistry,
        address providerRegistry,
        address serviceRegistry,
        address sanctionsOracle,
        address canonicalToken
    ) internal view {
        require(identityRegistry.code.length != 0, "identity not contract");
        require(providerRegistry.code.length != 0, "provider registry not contract");
        require(serviceRegistry.code.length != 0, "service registry not contract");
        require(sanctionsOracle.code.length != 0, "sanctions oracle not contract");
        require(canonicalToken.code.length != 0, "token not contract");

        IReputationProviderDependencies provider = IReputationProviderDependencies(providerRegistry);
        require(provider.identity() == identityRegistry, "provider identity mismatch");
        require(provider.usdc() == canonicalToken, "provider token mismatch");
        require(provider.sanctionsOracle() == sanctionsOracle, "provider sanctions mismatch");
        (bool success, bytes memory data) =
            providerRegistry.staticcall(abi.encodeCall(IProviderRegistry.isRegistered, (type(uint256).max)));
        require(_isBool(success, data), "invalid provider registry");

        IReputationServiceDependencies service = IReputationServiceDependencies(serviceRegistry);
        require(service.identity() == identityRegistry, "service identity mismatch");
        require(service.providerRegistry() == providerRegistry, "service provider mismatch");
        require(service.sanctionsOracle() == sanctionsOracle, "service sanctions mismatch");
        (success, data) =
            serviceRegistry.staticcall(abi.encodeCall(IServiceRegistry.exists, (bytes32(type(uint256).max))));
        require(_isBool(success, data), "invalid service registry");
    }

    function _isBool(bool success, bytes memory data) private pure returns (bool) {
        return success && data.length == 32 && abi.decode(data, (uint256)) <= 1;
    }
}
