// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {ReputationSchemas} from "../src/reputation/ReputationSchemas.sol";
import {ReputationDependencyValidation} from "./ReputationDependencyValidation.sol";
import {ReputationEASIdentity} from "./ReputationEASIdentity.sol";
import {ReputationSafeValidation} from "./ReputationSafeValidation.sol";

/// @notice Deploys a configured reputation resolver that remains paused until
///         its reviewed Safe accepts administration and explicitly activates it.
contract DeployReputationStorage is ReputationEASIdentity, ReputationDependencyValidation, ReputationSafeValidation {
    struct DeploymentConfig {
        address admin;
        address finalAdmin;
        address pauseGuardian;
        address orderSigner;
        address identityRegistry;
        address providerRegistry;
        address serviceRegistry;
        address sanctionsOracle;
        address canonicalToken;
        address eas;
        bool allowNonCanonicalEAS;
        SafeProfile safeProfile;
    }

    error InvalidPauseGuardian();
    error GovernanceRoleConflict();
    error DeploymentNotReady();

    function run() external returns (address proxyAddress, bytes32 outcomeSchema, bytes32 confirmationSchema) {
        uint256 adminPrivateKey = vm.envUint("STANDARD_REPUTATION_ADMIN_PRIVATE_KEY");
        address[] memory noModules = new address[](0);
        DeploymentConfig memory config = DeploymentConfig({
            admin: vm.addr(adminPrivateKey),
            finalAdmin: vm.envAddress("STANDARD_REPUTATION_FINAL_ADMIN"),
            pauseGuardian: vm.envAddress("STANDARD_REPUTATION_PAUSE_GUARDIAN"),
            orderSigner: vm.envAddress("STANDARD_REPUTATION_ORDER_SIGNER"),
            identityRegistry: vm.envAddress("IDENTITY_REGISTRY_ADDRESS"),
            providerRegistry: vm.envAddress("PROVIDER_REGISTRY_ADDRESS"),
            serviceRegistry: vm.envAddress("SERVICE_REGISTRY_ADDRESS"),
            sanctionsOracle: vm.envAddress("SANCTIONS_ORACLE_ADDRESS"),
            canonicalToken: vm.envAddress("STANDARD_RAIL_CANONICAL_TOKEN"),
            eas: vm.envAddress("EAS_ADDRESS"),
            allowNonCanonicalEAS: vm.envOr("STANDARD_REPUTATION_ALLOW_NON_CANONICAL_EAS", false),
            safeProfile: SafeProfile({
                singleton: vm.envAddress("STANDARD_REPUTATION_SAFE_SINGLETON"),
                owners: vm.envAddress("STANDARD_REPUTATION_SAFE_OWNERS", ","),
                threshold: vm.envUint("STANDARD_REPUTATION_SAFE_THRESHOLD"),
                modules: vm.envOr("STANDARD_REPUTATION_SAFE_MODULES", ",", noModules),
                guard: vm.envOr("STANDARD_REPUTATION_SAFE_GUARD", address(0)),
                fallbackHandler: vm.envAddress("STANDARD_REPUTATION_SAFE_FALLBACK_HANDLER")
            })
        });

        _validateDependencies(
            config.identityRegistry,
            config.providerRegistry,
            config.serviceRegistry,
            config.sanctionsOracle,
            config.canonicalToken
        );
        _validateGovernance(config);
        ISchemaRegistry schemaRegistry = _validateEAS(config.eas, config.allowNonCanonicalEAS);

        vm.startBroadcast(adminPrivateKey);
        ReputationStorage implementation = new ReputationStorage();
        ReputationStorage reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            config.orderSigner,
                            config.identityRegistry,
                            config.providerRegistry,
                            config.serviceRegistry,
                            config.sanctionsOracle,
                            config.canonicalToken,
                            config.admin
                        )
                    )
                )
            )
        );
        reputation.setPauseGuardian(config.pauseGuardian);
        reputation.pauseExternalDependency();
        reputation.setEAS(config.eas);
        outcomeSchema = _registerOrLoad(schemaRegistry, ReputationSchemas.outcomeSchema(), address(reputation), false);
        confirmationSchema =
            _registerOrLoad(schemaRegistry, ReputationSchemas.confirmationSchema(), address(reputation), true);
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        reputation.transferAdmin(config.finalAdmin);
        vm.stopBroadcast();

        _validateEAS(config.eas, config.allowNonCanonicalEAS);
        _requireHandoffReady(reputation, config, outcomeSchema, confirmationSchema);
        proxyAddress = address(reputation);
    }

    function _validateGovernance(DeploymentConfig memory config) internal view {
        _validateSafeProfile(config.finalAdmin, config.safeProfile);
        if (
            config.pauseGuardian == address(0) || config.pauseGuardian == config.admin
                || config.pauseGuardian == config.finalAdmin || config.pauseGuardian == config.orderSigner
        ) revert InvalidPauseGuardian();
        if (
            config.orderSigner == address(0) || config.orderSigner == config.admin
                || config.orderSigner == config.finalAdmin
        ) revert GovernanceRoleConflict();
    }

    function _requireHandoffReady(
        ReputationStorage reputation,
        DeploymentConfig memory config,
        bytes32 outcomeSchema,
        bytes32 confirmationSchema
    ) internal view {
        _validateDependencies(
            config.identityRegistry,
            config.providerRegistry,
            config.serviceRegistry,
            config.sanctionsOracle,
            config.canonicalToken
        );
        _validateSafeProfile(config.finalAdmin, config.safeProfile);
        bool ready = reputation.isConfigured() && reputation.admin() == config.admin
            && reputation.pendingAdmin() == config.finalAdmin && reputation.pauseGuardian() == config.pauseGuardian
            && reputation.externalDependencyPaused() && reputation.orderSigner() == config.orderSigner
            && reputation.identityRegistry() == config.identityRegistry
            && address(reputation.providerRegistry()) == config.providerRegistry
            && address(reputation.serviceRegistry()) == config.serviceRegistry
            && address(reputation.sanctionsOracle()) == config.sanctionsOracle
            && reputation.canonicalToken() == config.canonicalToken && address(reputation.eas()) == config.eas
            && reputation.outcomeSchema() == outcomeSchema && reputation.confirmationSchema() == confirmationSchema;
        if (!ready) revert DeploymentNotReady();
    }

    function _registerOrLoad(ISchemaRegistry registry, string memory schema, address resolver, bool revocable)
        private
        returns (bytes32 uid)
    {
        uid = keccak256(abi.encodePacked(schema, resolver, revocable));
        if (registry.getSchema(uid).uid == bytes32(0)) {
            uid = registry.register(schema, resolver, revocable);
        }
    }
}
