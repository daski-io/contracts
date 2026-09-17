// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";

/// @notice Read-only proxy, wiring and administration checks shared by the
///         marketplace registry genesis script and its verifier.
abstract contract MarketplaceRegistryValidation is Script {
    uint256 private constant BASE_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Registries {
        address agentIndex;
        address validationRegistry;
        address providerRegistry;
        address serviceRegistry;
    }

    struct Dependencies {
        address identityRegistry;
        address sanctionsOracle;
        address canonicalToken;
    }

    error UnsupportedRegistryChain(uint256 chainId);
    error RegistryHasNoCode(address registry);
    error RegistryImplementationNotSet(address registry);
    error RegistryTypeMismatch(address registry);
    error RegistryIdentityMismatch(address registry, address expected, address actual);
    error RegistrySanctionsOracleMismatch(address registry, address expected, address actual);
    error ProviderRegistryTokenMismatch(address expected, address actual);
    error ServiceRegistryProviderMismatch(address expected, address actual);
    error RegistryAdminMismatch(address registry, address expected, address actual);
    error RegistryPendingAdminMismatch(address registry, address expected, address actual);

    function _requireSupportedChain() internal view {
        if (block.chainid != BASE_CHAIN_ID && block.chainid != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedRegistryChain(block.chainid);
        }
    }

    function _list(Registries memory registries) internal pure returns (address[4] memory) {
        return
            [
                registries.agentIndex,
                registries.validationRegistry,
                registries.providerRegistry,
                registries.serviceRegistry
            ];
    }

    /// @notice Every registry is an ERC-1967 proxy with code whose
    ///         implementation slot names a contract.
    function _requireImplementations(Registries memory registries)
        internal
        view
        returns (Registries memory implementations)
    {
        implementations.agentIndex = _requireProxy(registries.agentIndex);
        implementations.validationRegistry = _requireProxy(registries.validationRegistry);
        implementations.providerRegistry = _requireProxy(registries.providerRegistry);
        implementations.serviceRegistry = _requireProxy(registries.serviceRegistry);
    }

    /// @notice Each address is the registry it is named as, and the four share
    ///         one identity registry, one sanctions oracle, the expected
    ///         listing-fee token and the expected provider registry.
    function _requireWiring(Registries memory registries, Dependencies memory expected) internal view {
        _requireRegistryTypes(registries);

        _requireIdentity(
            registries.agentIndex, expected.identityRegistry, AgentIndex(registries.agentIndex).getIdentityRegistry()
        );
        _requireIdentity(
            registries.validationRegistry,
            expected.identityRegistry,
            ValidationRegistry(registries.validationRegistry).getIdentityRegistry()
        );
        _requireIdentity(
            registries.providerRegistry,
            expected.identityRegistry,
            address(ProviderRegistry(registries.providerRegistry).identity())
        );
        _requireIdentity(
            registries.serviceRegistry,
            expected.identityRegistry,
            address(ServiceRegistry(registries.serviceRegistry).identity())
        );

        address token = address(ProviderRegistry(registries.providerRegistry).usdc());
        if (token != expected.canonicalToken) revert ProviderRegistryTokenMismatch(expected.canonicalToken, token);
        address providerRegistry = address(ServiceRegistry(registries.serviceRegistry).providerRegistry());
        if (providerRegistry != registries.providerRegistry) {
            revert ServiceRegistryProviderMismatch(registries.providerRegistry, providerRegistry);
        }

        address[4] memory proxies = _list(registries);
        for (uint256 i = 0; i < proxies.length; i++) {
            address oracle = address(ISanctionsGuard(proxies[i]).sanctionsOracle());
            if (oracle != expected.sanctionsOracle) {
                revert RegistrySanctionsOracleMismatch(proxies[i], expected.sanctionsOracle, oracle);
            }
        }
    }

    function _requireAdministration(Registries memory registries, address expectedAdmin, address expectedPendingAdmin)
        internal
        view
    {
        address[4] memory proxies = _list(registries);
        for (uint256 i = 0; i < proxies.length; i++) {
            Admin2StepUpgradeable registry = Admin2StepUpgradeable(proxies[i]);
            address admin = registry.admin();
            if (admin != expectedAdmin) revert RegistryAdminMismatch(proxies[i], expectedAdmin, admin);
            address pendingAdmin = registry.pendingAdmin();
            if (pendingAdmin != expectedPendingAdmin) {
                revert RegistryPendingAdminMismatch(proxies[i], expectedPendingAdmin, pendingAdmin);
            }
        }
    }

    function _requireProxy(address proxy) private view returns (address implementation) {
        if (proxy.code.length == 0) revert RegistryHasNoCode(proxy);
        implementation = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
        if (implementation.code.length == 0) revert RegistryImplementationNotSet(proxy);
    }

    /// @dev One selector per registry that no other registry answers, so two
    ///      addresses cannot be swapped and a registry of another type cannot
    ///      stand in.
    function _requireRegistryTypes(Registries memory registries) private view {
        try AgentIndex(registries.agentIndex).registrationNonce(address(0)) returns (uint256) {}
        catch {
            revert RegistryTypeMismatch(registries.agentIndex);
        }
        try ValidationRegistry(registries.validationRegistry).computeValidationKey(0, bytes32(0)) returns (bytes32) {}
        catch {
            revert RegistryTypeMismatch(registries.validationRegistry);
        }
        try ProviderRegistry(registries.providerRegistry).listingFee() returns (uint256) {}
        catch {
            revert RegistryTypeMismatch(registries.providerRegistry);
        }
        try ServiceRegistry(registries.serviceRegistry).getServiceCountByProvider(0) returns (uint256) {}
        catch {
            revert RegistryTypeMismatch(registries.serviceRegistry);
        }
    }

    function _requireIdentity(address registry, address expected, address actual) private pure {
        if (actual != expected) revert RegistryIdentityMismatch(registry, expected, actual);
    }
}
