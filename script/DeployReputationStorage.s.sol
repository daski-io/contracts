// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {ReputationSchemas} from "../src/reputation/ReputationSchemas.sol";
import {ReputationDependencyValidation} from "./ReputationDependencyValidation.sol";
import {ReputationEASIdentity} from "./ReputationEASIdentity.sol";
import {ReputationSafeValidation} from "./ReputationSafeValidation.sol";

/// @notice Deploys a configured reputation resolver that remains paused until
///         its reviewed Safe accepts administration and explicitly activates it.
///
///         The broadcaster is the bootstrap admin. It registers the outcome,
///         confirmation and recovery schemas with the new proxy as resolver,
///         finalizes the configuration, binds the recovery schema, optionally
///         enables recovery submissions, and proposes the Safe as admin. EAS
///         and its SchemaRegistry are the canonical predeploys of the
///         executing chain.
///
///         STANDARD_REPUTATION_ADMIN_PRIVATE_KEY             bootstrap admin and broadcaster
///         STANDARD_REPUTATION_FINAL_ADMIN                   reviewed governance Safe
///         STANDARD_REPUTATION_PAUSE_GUARDIAN                distinct nonzero pause guardian
///         STANDARD_REPUTATION_ORDER_SIGNER                  order and refund permit signer
///         IDENTITY_REGISTRY_ADDRESS                         canonical ERC-8004 IdentityRegistry
///         PROVIDER_REGISTRY_ADDRESS                         ProviderRegistry proxy
///         SERVICE_REGISTRY_ADDRESS                          ServiceRegistry proxy
///         SANCTIONS_ORACLE_ADDRESS                          Chainalysis-compatible sanctions oracle
///         STANDARD_RAIL_CANONICAL_TOKEN                     canonical payment token
///         STANDARD_REPUTATION_RECOVERY_SUBMISSIONS_ENABLED  optional, default false; true also
///                                                           enables recovery submissions
contract DeployReputationStorage is
    Script,
    ReputationEASIdentity,
    ReputationDependencyValidation,
    ReputationSafeValidation
{
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
        bool recoverySubmissionsEnabled;
    }

    error InvalidPauseGuardian();
    error GovernanceRoleConflict();
    error DeploymentNotReady();

    function run()
        external
        returns (address proxyAddress, bytes32 outcomeSchema, bytes32 confirmationSchema, bytes32 recoverySchema)
    {
        uint256 adminPrivateKey = vm.envUint("STANDARD_REPUTATION_ADMIN_PRIVATE_KEY");
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
            eas: canonicalEAS(block.chainid),
            recoverySubmissionsEnabled: vm.envOr("STANDARD_REPUTATION_RECOVERY_SUBMISSIONS_ENABLED", false)
        });
        return _deploy(config, adminPrivateKey);
    }

    function _deploy(DeploymentConfig memory config, uint256 adminPrivateKey)
        internal
        returns (address proxyAddress, bytes32 outcomeSchema, bytes32 confirmationSchema, bytes32 recoverySchema)
    {
        _validateDependencies(
            config.identityRegistry,
            config.providerRegistry,
            config.serviceRegistry,
            config.sanctionsOracle,
            config.canonicalToken
        );
        _validateGovernance(config);
        ISchemaRegistry schemaRegistry = _validateEAS(config.eas);

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
        recoverySchema = _registerOrLoad(schemaRegistry, ReputationSchemas.recoverySchema(), address(reputation), false);
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        reputation.configureRecoverySchema(recoverySchema);
        if (config.recoverySubmissionsEnabled) reputation.setRecoverySubmissionsEnabled(true);
        reputation.transferAdmin(config.finalAdmin);
        vm.stopBroadcast();

        _validateEAS(config.eas);
        _requireHandoffReady(reputation, config, outcomeSchema, confirmationSchema, recoverySchema);
        proxyAddress = address(reputation);
    }

    function _validateGovernance(DeploymentConfig memory config) internal view {
        _validateSafe(config.finalAdmin);
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
        bytes32 confirmationSchema,
        bytes32 recoverySchema
    ) internal view {
        _validateDependencies(
            config.identityRegistry,
            config.providerRegistry,
            config.serviceRegistry,
            config.sanctionsOracle,
            config.canonicalToken
        );
        _validateSafe(config.finalAdmin);
        bool ready = reputation.isConfigured() && reputation.admin() == config.admin
            && reputation.pendingAdmin() == config.finalAdmin && reputation.pauseGuardian() == config.pauseGuardian
            && reputation.externalDependencyPaused() && reputation.orderSigner() == config.orderSigner
            && reputation.identityRegistry() == config.identityRegistry
            && address(reputation.providerRegistry()) == config.providerRegistry
            && address(reputation.serviceRegistry()) == config.serviceRegistry
            && address(reputation.sanctionsOracle()) == config.sanctionsOracle
            && reputation.canonicalToken() == config.canonicalToken && address(reputation.eas()) == config.eas
            && reputation.outcomeSchema() == outcomeSchema && reputation.confirmationSchema() == confirmationSchema
            && reputation.recoverySchema() == recoverySchema
            && reputation.recoverySubmissionsEnabled() == config.recoverySubmissionsEnabled;
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
