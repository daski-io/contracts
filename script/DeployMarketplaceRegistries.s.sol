// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";
import {MarketplaceRegistryValidation} from "./MarketplaceRegistryValidation.sol";
import {ReputationSafeValidation} from "./ReputationSafeValidation.sol";
import {StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";

/// @notice Genesis deployment of AgentIndex, ValidationRegistry,
///         ProviderRegistry and ServiceRegistry as ERC-1967 UUPS proxies on
///         Base or Base Sepolia.
///
///         The broadcaster is only the bootstrap admin. The script pauses
///         every registry, sets its pause guardian and proposes the reviewed
///         Safe as admin, so it ends with four paused proxies whose pending
///         admin is the Safe. Administration ends with the Safe: it accepts
///         each proxy and only then can unpause it. The broadcaster stays
///         admin of the paused proxies until that acceptance and holds no
///         role after it. Run VerifyMarketplaceRegistries once the Safe has
///         accepted.
///
///         The broadcaster comes from the standard Foundry wallet options
///         (hardware wallet, keystore or --sender); no key is read from the
///         environment.
///
///         IDENTITY_REGISTRY_ADDRESS              canonical ERC-8004 IdentityRegistry
///         SANCTIONS_ORACLE_ADDRESS               Chainalysis-compatible sanctions oracle
///         MARKETPLACE_REGISTRIES_FINAL_ADMIN     reviewed governance Safe
///         MARKETPLACE_REGISTRIES_PAUSE_GUARDIAN  distinct nonzero pause guardian
///         PROVIDER_REGISTRY_TREASURY             listing-fee recipient
///         PROVIDER_REGISTRY_LISTING_FEE          listing fee in atomic USDC units
///
///         The listing-fee token is the reviewed canonical Circle USDC of the
///         executing chain.
contract DeployMarketplaceRegistries is MarketplaceRegistryValidation, ReputationSafeValidation {
    struct Config {
        address identityRegistry;
        address sanctionsOracle;
        address finalAdmin;
        address pauseGuardian;
        address treasury;
        uint256 listingFee;
    }

    error DependencyHasNoCode(address dependency);
    error InvalidPauseGuardian();
    error InvalidTreasury();
    error GovernanceRoleConflict();
    error BroadcasterUnavailable();
    error DeploymentNotReady();

    function run()
        external
        returns (address agentIndex, address validationRegistry, address providerRegistry, address serviceRegistry)
    {
        Registries memory registries = _deploy(_readConfig());
        return
            (
                registries.agentIndex,
                registries.validationRegistry,
                registries.providerRegistry,
                registries.serviceRegistry
            );
    }

    function _readConfig() internal view returns (Config memory config) {
        config.identityRegistry = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        config.sanctionsOracle = vm.envAddress("SANCTIONS_ORACLE_ADDRESS");
        config.finalAdmin = vm.envAddress("MARKETPLACE_REGISTRIES_FINAL_ADMIN");
        config.pauseGuardian = vm.envAddress("MARKETPLACE_REGISTRIES_PAUSE_GUARDIAN");
        config.treasury = vm.envAddress("PROVIDER_REGISTRY_TREASURY");
        config.listingFee = vm.envUint("PROVIDER_REGISTRY_LISTING_FEE");
    }

    function _deploy(Config memory config) internal returns (Registries memory registries) {
        Dependencies memory dependencies = _validateConfig(config);
        address deployer = _broadcaster();
        _requireSeparateDeployer(config, deployer);

        vm.startBroadcast();
        registries = _deployProxies(config, dependencies, deployer);
        vm.stopBroadcast();

        _requireHandoffReady(registries, config, dependencies, deployer);
    }

    function _validateConfig(Config memory config) internal view returns (Dependencies memory dependencies) {
        _requireSupportedChain();
        dependencies = Dependencies({
            identityRegistry: config.identityRegistry,
            sanctionsOracle: config.sanctionsOracle,
            canonicalToken: StandardRailCircleUSDC.canonicalToken(block.chainid)
        });
        if (dependencies.identityRegistry.code.length == 0) revert DependencyHasNoCode(dependencies.identityRegistry);
        if (dependencies.sanctionsOracle.code.length == 0) revert DependencyHasNoCode(dependencies.sanctionsOracle);
        if (dependencies.canonicalToken.code.length == 0) revert DependencyHasNoCode(dependencies.canonicalToken);

        _validateSafe(config.finalAdmin);
        if (config.pauseGuardian == address(0) || config.pauseGuardian == config.finalAdmin) {
            revert InvalidPauseGuardian();
        }
        if (config.treasury == address(0)) revert InvalidTreasury();
    }

    /// @dev The account that signs the broadcast, whichever wallet option
    ///      supplied it. It is read in a broadcast window of its own that sends
    ///      nothing, so every refusal happens before the first transaction.
    function _broadcaster() private returns (address deployer) {
        vm.startBroadcast();
        VmSafe.CallerMode mode;
        (mode, deployer,) = vm.readCallers();
        vm.stopBroadcast();
        if (mode != VmSafe.CallerMode.RecurrentBroadcast || deployer == address(0)) revert BroadcasterUnavailable();
    }

    /// @dev The bootstrap admin keeps nothing once the Safe has accepted.
    function _requireSeparateDeployer(Config memory config, address deployer) private pure {
        if (deployer == config.finalAdmin || deployer == config.treasury) revert GovernanceRoleConflict();
        if (deployer == config.pauseGuardian) revert InvalidPauseGuardian();
    }

    function _deployProxies(Config memory config, Dependencies memory dependencies, address deployer)
        private
        returns (Registries memory registries)
    {
        registries.agentIndex = _deployProxy(
            address(new AgentIndex()),
            abi.encodeCall(
                AgentIndex.initialize, (dependencies.identityRegistry, dependencies.sanctionsOracle, deployer)
            ),
            config
        );
        registries.validationRegistry = _deployProxy(
            address(new ValidationRegistry()),
            abi.encodeCall(
                ValidationRegistry.initialize, (dependencies.identityRegistry, dependencies.sanctionsOracle, deployer)
            ),
            config
        );
        registries.providerRegistry = _deployProxy(
            address(new ProviderRegistry()),
            abi.encodeCall(
                ProviderRegistry.initialize,
                (
                    dependencies.identityRegistry,
                    dependencies.canonicalToken,
                    config.treasury,
                    config.listingFee,
                    dependencies.sanctionsOracle,
                    deployer
                )
            ),
            config
        );
        registries.serviceRegistry = _deployProxy(
            address(new ServiceRegistry()),
            abi.encodeCall(
                ServiceRegistry.initialize,
                (dependencies.identityRegistry, registries.providerRegistry, dependencies.sanctionsOracle, deployer)
            ),
            config
        );
    }

    /// @dev Creates and initializes one proxy in a single transaction, then
    ///      pauses it, sets its guardian and proposes the Safe before the next
    ///      registry is deployed, so an interrupted run leaves at most one
    ///      registry unpaused.
    function _deployProxy(address implementation, bytes memory initializer, Config memory config)
        private
        returns (address proxy)
    {
        proxy = address(new ERC1967Proxy(implementation, initializer));
        Admin2StepUpgradeable registry = Admin2StepUpgradeable(proxy);
        registry.pauseExternalDependency();
        registry.setPauseGuardian(config.pauseGuardian);
        registry.transferAdmin(config.finalAdmin);
    }

    function _requireHandoffReady(
        Registries memory registries,
        Config memory config,
        Dependencies memory dependencies,
        address deployer
    ) internal view {
        _validateSafe(config.finalAdmin);
        _requireImplementations(registries);
        _requireWiring(registries, dependencies);
        _requireAdministration(registries, deployer, config.finalAdmin);

        ProviderRegistry providerRegistry = ProviderRegistry(registries.providerRegistry);
        bool ready =
            providerRegistry.treasury() == config.treasury && providerRegistry.listingFee() == config.listingFee;
        address[4] memory proxies = _list(registries);
        for (uint256 i = 0; i < proxies.length; i++) {
            Admin2StepUpgradeable registry = Admin2StepUpgradeable(proxies[i]);
            ready = ready && registry.pauseGuardian() == config.pauseGuardian && registry.externalDependencyPaused();
        }
        if (!ready) revert DeploymentNotReady();
    }
}
