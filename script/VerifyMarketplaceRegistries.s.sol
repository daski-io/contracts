// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarketplaceRegistryValidation} from "./MarketplaceRegistryValidation.sol";
import {ReputationSafeValidation} from "./ReputationSafeValidation.sol";
import {StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";

/// @notice Read-only check of a marketplace registry deployment after the
///         governance Safe has accepted administration. It sends nothing and
///         changes no state.
///
///         Every proxy must have code and an ERC-1967 implementation with
///         code, be the registry it is named as, share the expected identity
///         registry and sanctions oracle, use the reviewed Circle USDC of the
///         executing chain for listing fees, and have the reviewed Safe as
///         admin with no pending admin. ServiceRegistry must point at the
///         given ProviderRegistry. The implementation addresses are returned
///         for the release record.
///
///         AGENT_INDEX_ADDRESS, VALIDATION_REGISTRY_ADDRESS,
///         PROVIDER_REGISTRY_ADDRESS, SERVICE_REGISTRY_ADDRESS   the four proxies
///         IDENTITY_REGISTRY_ADDRESS                             expected identity registry
///         SANCTIONS_ORACLE_ADDRESS                              expected sanctions oracle
///         MARKETPLACE_REGISTRIES_FINAL_ADMIN                    expected governance Safe
contract VerifyMarketplaceRegistries is MarketplaceRegistryValidation, ReputationSafeValidation {
    function run()
        external
        view
        returns (
            address agentIndexImplementation,
            address validationRegistryImplementation,
            address providerRegistryImplementation,
            address serviceRegistryImplementation
        )
    {
        Registries memory registries = Registries({
            agentIndex: vm.envAddress("AGENT_INDEX_ADDRESS"),
            validationRegistry: vm.envAddress("VALIDATION_REGISTRY_ADDRESS"),
            providerRegistry: vm.envAddress("PROVIDER_REGISTRY_ADDRESS"),
            serviceRegistry: vm.envAddress("SERVICE_REGISTRY_ADDRESS")
        });
        Registries memory implementations = _verify(
            registries,
            vm.envAddress("IDENTITY_REGISTRY_ADDRESS"),
            vm.envAddress("SANCTIONS_ORACLE_ADDRESS"),
            vm.envAddress("MARKETPLACE_REGISTRIES_FINAL_ADMIN")
        );
        return (
            implementations.agentIndex,
            implementations.validationRegistry,
            implementations.providerRegistry,
            implementations.serviceRegistry
        );
    }

    function _verify(Registries memory registries, address identityRegistry, address sanctionsOracle, address safe)
        internal
        view
        returns (Registries memory implementations)
    {
        _requireSupportedChain();
        _validateSafe(safe);
        implementations = _requireImplementations(registries);
        _requireWiring(
            registries,
            Dependencies({
                identityRegistry: identityRegistry,
                sanctionsOracle: sanctionsOracle,
                canonicalToken: StandardRailCircleUSDC.canonicalToken(block.chainid)
            })
        );
        _requireAdministration(registries, safe, address(0));
    }
}
