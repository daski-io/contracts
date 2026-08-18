// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDependencyValidation} from "../src/utils/LibDependencyValidation.sol";

/// @notice Fail-closed dependency and cross-registry wiring preflight for reputation deployment.
abstract contract ReputationDependencyValidation {
    function _validateDependencies(
        address identityRegistry,
        address providerRegistry,
        address serviceRegistry,
        address sanctionsOracle,
        address canonicalToken
    ) internal view {
        LibDependencyValidation.requireIdentity(identityRegistry);
        LibDependencyValidation.requireUsdc(canonicalToken);
        LibDependencyValidation.requireSanctionsOracle(sanctionsOracle);
        LibDependencyValidation.requireProviderRegistry(providerRegistry, identityRegistry);
        LibDependencyValidation.requireProviderToken(providerRegistry, canonicalToken);
        LibDependencyValidation.requireSanctionsBinding(providerRegistry, sanctionsOracle);
        LibDependencyValidation.requireServiceRegistry(serviceRegistry, identityRegistry, providerRegistry);
        LibDependencyValidation.requireSanctionsBinding(serviceRegistry, sanctionsOracle);
    }
}
