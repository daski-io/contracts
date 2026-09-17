// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {DeployMarketplaceRegistries} from "../script/DeployMarketplaceRegistries.s.sol";
import {MarketplaceRegistryValidation} from "../script/MarketplaceRegistryValidation.sol";
import {ReputationSafeValidation} from "../script/ReputationSafeValidation.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";
import {
    DeployMarketplaceRegistriesHarness,
    VerifyMarketplaceRegistriesHarness
} from "./helpers/MarketplaceDeploymentHarness.sol";
import {
    ReputationSafeFallbackHandlerStub,
    ReputationSafeSingletonStub,
    ThresholdSafeStub
} from "./helpers/ReputationDeploymentHarness.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract DeployMarketplaceRegistriesTest is Test {
    uint256 private constant BASE_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant LISTING_FEE = 1_000_000;

    DeployMarketplaceRegistriesHarness private script;
    VerifyMarketplaceRegistriesHarness private verifier;
    ReputationSafeSingletonStub private safeSingleton;
    ReputationSafeFallbackHandlerStub private safeHandler;
    MockCanonicalIdentityRegistry private identity;
    MockSanctionsList private sanctions;
    ThresholdSafeStub private safe;

    address private guardian = makeAddr("pause-guardian");
    address private treasury = makeAddr("treasury");
    address private provider = makeAddr("provider");

    function setUp() public {
        script = new DeployMarketplaceRegistriesHarness();
        verifier = new VerifyMarketplaceRegistriesHarness();
        safeSingleton = new ReputationSafeSingletonStub();
        safeHandler = new ReputationSafeFallbackHandlerStub();
        script.setReviewedSafeContracts(address(safeSingleton), address(safeHandler));
        verifier.setReviewedSafeContracts(address(safeSingleton), address(safeHandler));

        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();
        safe = _safe(2, _owners(2));

        MockUSDC tokenCodeSource = new MockUSDC();
        vm.etch(BASE_USDC, address(tokenCodeSource).code);
        vm.etch(BASE_SEPOLIA_USDC, address(tokenCodeSource).code);
        vm.chainId(BASE_CHAIN_ID);
    }

    // ------------------------------------------------------------------
    // Genesis deployment
    // ------------------------------------------------------------------

    function test_deploysPausedRegistriesPendingTheSafeOnBase() public {
        _checkGenesisState(BASE_CHAIN_ID, BASE_USDC);
    }

    function test_deploysPausedRegistriesPendingTheSafeOnBaseSepolia() public {
        _checkGenesisState(BASE_SEPOLIA_CHAIN_ID, BASE_SEPOLIA_USDC);
    }

    function test_safeAcceptanceEndsDeployerAuthorityOnBase() public {
        _checkHandoffEndsDeployerAuthority(BASE_CHAIN_ID, BASE_USDC);
    }

    function test_safeAcceptanceEndsDeployerAuthorityOnBaseSepolia() public {
        _checkHandoffEndsDeployerAuthority(BASE_SEPOLIA_CHAIN_ID, BASE_SEPOLIA_USDC);
    }

    function test_bootstrapAdminCannotActivateWhileTheSafeIsPending() public {
        MarketplaceRegistryValidation.Registries memory registries = script.deploy(_config());
        address deployer = Admin2StepUpgradeable(registries.agentIndex).admin();
        address[4] memory proxies = _list(registries);
        for (uint256 i = 0; i < proxies.length; i++) {
            vm.prank(deployer);
            vm.expectRevert("admin transfer pending");
            Admin2StepUpgradeable(proxies[i]).unpauseExternalDependency();
        }

        vm.prank(provider);
        uint256 agentId = identity.register("ipfs://provider");
        vm.prank(provider);
        vm.expectRevert("external dependency paused");
        ProviderRegistry(registries.providerRegistry).register(agentId);
        vm.prank(provider);
        vm.expectRevert("external dependency paused");
        AgentIndex(registries.agentIndex).claim(agentId);
    }

    function test_handoffReadinessRefusesDriftFromTheReviewedInputs() public {
        MarketplaceRegistryValidation.Registries memory registries = script.deploy(_config());
        address deployer = _broadcaster();
        script.requireHandoffReady(registries, _config(), deployer);

        // Until the Safe accepts, the bootstrap admin can still change a registry; the check refuses each change.
        uint256 snapshot = vm.snapshotState();
        vm.prank(deployer);
        ProviderRegistry(registries.providerRegistry).setListingFee(LISTING_FEE + 1);
        vm.expectRevert(DeployMarketplaceRegistries.DeploymentNotReady.selector);
        script.requireHandoffReady(registries, _config(), deployer);
        vm.revertToState(snapshot);

        vm.prank(deployer);
        ProviderRegistry(registries.providerRegistry).setTreasury(makeAddr("other-treasury"));
        vm.expectRevert(DeployMarketplaceRegistries.DeploymentNotReady.selector);
        script.requireHandoffReady(registries, _config(), deployer);
        vm.revertToState(snapshot);

        vm.prank(deployer);
        Admin2StepUpgradeable(registries.agentIndex).setPauseGuardian(makeAddr("other-guardian"));
        vm.expectRevert(DeployMarketplaceRegistries.DeploymentNotReady.selector);
        script.requireHandoffReady(registries, _config(), deployer);
        vm.revertToState(snapshot);

        address otherAdmin = makeAddr("other-admin");
        vm.prank(deployer);
        Admin2StepUpgradeable(registries.serviceRegistry).transferAdmin(otherAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryPendingAdminMismatch.selector,
                registries.serviceRegistry,
                address(safe),
                otherAdmin
            )
        );
        script.requireHandoffReady(registries, _config(), deployer);
    }

    // ------------------------------------------------------------------
    // Refusals
    // ------------------------------------------------------------------

    function test_refusesUnsupportedChain() public {
        uint256[3] memory unsupported = [uint256(1), 31_337, 11_155_111];
        for (uint256 i = 0; i < unsupported.length; i++) {
            vm.chainId(unsupported[i]);
            vm.expectRevert(
                abi.encodeWithSelector(MarketplaceRegistryValidation.UnsupportedRegistryChain.selector, unsupported[i])
            );
            script.deploy(_config());
        }
    }

    function test_refusesExternallyOwnedAdminOnBothChains() public {
        DeployMarketplaceRegistries.Config memory config = _config();
        config.finalAdmin = makeAddr("eoa-admin");
        uint256[2] memory chains = [BASE_CHAIN_ID, BASE_SEPOLIA_CHAIN_ID];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ReputationSafeValidation.FinalAdminMustBeReviewedSafe.selector, config.finalAdmin
                )
            );
            script.deploy(config);
        }
    }

    function test_refusesOneOfOneSafeOnBothChains() public {
        DeployMarketplaceRegistries.Config memory oneOfOne = _config();
        oneOfOne.finalAdmin = address(_safe(1, _owners(1)));
        DeployMarketplaceRegistries.Config memory oneOfTwo = _config();
        oneOfTwo.finalAdmin = address(_safe(1, _owners(2)));

        uint256[2] memory chains = [BASE_CHAIN_ID, BASE_SEPOLIA_CHAIN_ID];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            vm.expectRevert(ReputationSafeValidation.InvalidSafeOwners.selector);
            script.deploy(oneOfOne);
            vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.InvalidSafeThreshold.selector, 1, 2));
            script.deploy(oneOfTwo);
        }
    }

    function test_refusesSafeWithModuleOrGuard() public {
        ThresholdSafeStub withModule = _safe(2, _owners(2));
        address[] memory modules = new address[](1);
        modules[0] = makeAddr("module");
        withModule.setModules(modules);
        DeployMarketplaceRegistries.Config memory config = _config();
        config.finalAdmin = address(withModule);
        vm.expectRevert(ReputationSafeValidation.InvalidSafeModules.selector);
        script.deploy(config);

        ThresholdSafeStub withGuard = _safe(2, _owners(2));
        withGuard.setGuard(makeAddr("guard"));
        config.finalAdmin = address(withGuard);
        vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeGuard.selector);
        script.deploy(config);
    }

    function test_refusesGuardianOrTreasuryThatKeepsAuthorityTogether() public {
        address deployer = _broadcaster();

        address[3] memory invalidGuardians = [address(0), address(safe), deployer];
        for (uint256 i = 0; i < invalidGuardians.length; i++) {
            DeployMarketplaceRegistries.Config memory config = _config();
            config.pauseGuardian = invalidGuardians[i];
            vm.expectRevert(DeployMarketplaceRegistries.InvalidPauseGuardian.selector);
            script.deploy(config);
        }

        DeployMarketplaceRegistries.Config memory treasuryConfig = _config();
        treasuryConfig.treasury = address(0);
        vm.expectRevert(DeployMarketplaceRegistries.InvalidTreasury.selector);
        script.deploy(treasuryConfig);

        treasuryConfig.treasury = deployer;
        vm.expectRevert(DeployMarketplaceRegistries.GovernanceRoleConflict.selector);
        script.deploy(treasuryConfig);
    }

    function test_refusesDependenciesWithoutCode() public {
        address missing = makeAddr("missing");

        DeployMarketplaceRegistries.Config memory config = _config();
        config.identityRegistry = missing;
        vm.expectRevert(abi.encodeWithSelector(DeployMarketplaceRegistries.DependencyHasNoCode.selector, missing));
        script.deploy(config);

        config = _config();
        config.sanctionsOracle = missing;
        vm.expectRevert(abi.encodeWithSelector(DeployMarketplaceRegistries.DependencyHasNoCode.selector, missing));
        script.deploy(config);

        vm.etch(BASE_USDC, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(DeployMarketplaceRegistries.DependencyHasNoCode.selector, BASE_USDC));
        script.deploy(_config());
    }

    // ------------------------------------------------------------------
    // Verifier
    // ------------------------------------------------------------------

    function test_verifierAcceptsFreshDeploymentOnBothChainsWithoutWriting() public {
        uint256[2] memory chains = [BASE_CHAIN_ID, BASE_SEPOLIA_CHAIN_ID];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            MarketplaceRegistryValidation.Registries memory registries = _deployAndAccept();

            // A successful static call cannot have written state.
            (bool success, bytes memory result) = address(verifier)
                .staticcall(
                    abi.encodeCall(verifier.verify, (registries, address(identity), address(sanctions), address(safe)))
                );
            assertTrue(success);
            MarketplaceRegistryValidation.Registries memory implementations =
                abi.decode(result, (MarketplaceRegistryValidation.Registries));
            assertEq(implementations.agentIndex, _implementation(registries.agentIndex));
            assertEq(implementations.validationRegistry, _implementation(registries.validationRegistry));
            assertEq(implementations.providerRegistry, _implementation(registries.providerRegistry));
            assertEq(implementations.serviceRegistry, _implementation(registries.serviceRegistry));
        }
    }

    function test_verifierRefusesUnfinishedHandoff() public {
        MarketplaceRegistryValidation.Registries memory registries = script.deploy(_config());
        address deployer = Admin2StepUpgradeable(registries.agentIndex).admin();

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryAdminMismatch.selector,
                registries.agentIndex,
                address(safe),
                deployer
            )
        );
        _verify(registries);

        // Three of four accepted is still unfinished.
        address[4] memory proxies = _list(registries);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(address(safe));
            Admin2StepUpgradeable(proxies[i]).acceptAdmin();
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryAdminMismatch.selector,
                registries.serviceRegistry,
                address(safe),
                deployer
            )
        );
        _verify(registries);

        vm.prank(address(safe));
        Admin2StepUpgradeable(registries.serviceRegistry).acceptAdmin();
        _verify(registries);

        // A later pending transfer is reported as well.
        address proposed = makeAddr("proposed-admin");
        vm.prank(address(safe));
        Admin2StepUpgradeable(registries.providerRegistry).transferAdmin(proposed);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryPendingAdminMismatch.selector,
                registries.providerRegistry,
                address(0),
                proposed
            )
        );
        _verify(registries);
    }

    function test_verifierRefusesAdminOtherThanTheExpectedSafe() public {
        MarketplaceRegistryValidation.Registries memory registries = _deployAndAccept();

        ThresholdSafeStub otherSafe = _safe(2, _owners(2));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryAdminMismatch.selector,
                registries.agentIndex,
                address(otherSafe),
                address(safe)
            )
        );
        verifier.verify(registries, address(identity), address(sanctions), address(otherSafe));

        address eoa = makeAddr("eoa-admin");
        vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.FinalAdminMustBeReviewedSafe.selector, eoa));
        verifier.verify(registries, address(identity), address(sanctions), eoa);

        // The Safe must still satisfy the reviewed controls when verified.
        safe.setThreshold(1);
        vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.InvalidSafeThreshold.selector, 1, 2));
        _verify(registries);
    }

    function test_verifierRefusesTamperedProxy() public {
        MarketplaceRegistryValidation.Registries memory registries = _deployAndAccept();
        _verify(registries);

        uint256 snapshot = vm.snapshotState();
        vm.store(registries.validationRegistry, ERC1967_IMPLEMENTATION_SLOT, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryImplementationNotSet.selector, registries.validationRegistry
            )
        );
        _verify(registries);
        vm.revertToState(snapshot);

        vm.store(
            registries.validationRegistry,
            ERC1967_IMPLEMENTATION_SLOT,
            bytes32(uint256(uint160(makeAddr("implementation-without-code"))))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryImplementationNotSet.selector, registries.validationRegistry
            )
        );
        _verify(registries);
        vm.revertToState(snapshot);

        vm.etch(registries.serviceRegistry, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(MarketplaceRegistryValidation.RegistryHasNoCode.selector, registries.serviceRegistry)
        );
        _verify(registries);
    }

    function test_verifierRefusesWrongWiring() public {
        MarketplaceRegistryValidation.Registries memory registries = _deployAndAccept();
        MarketplaceRegistryValidation.Registries memory other = _deployAndAccept();

        // A service registry that settles against another provider registry.
        MarketplaceRegistryValidation.Registries memory crossed = _copy(registries);
        crossed.serviceRegistry = other.serviceRegistry;
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.ServiceRegistryProviderMismatch.selector,
                registries.providerRegistry,
                other.providerRegistry
            )
        );
        _verify(crossed);

        // Two addresses swapped, and one registry standing in for another.
        MarketplaceRegistryValidation.Registries memory swapped = _copy(registries);
        swapped.agentIndex = registries.validationRegistry;
        swapped.validationRegistry = registries.agentIndex;
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryTypeMismatch.selector, registries.validationRegistry
            )
        );
        _verify(swapped);

        MarketplaceRegistryValidation.Registries memory standIn = _copy(registries);
        standIn.agentIndex = other.serviceRegistry;
        vm.expectRevert(
            abi.encodeWithSelector(MarketplaceRegistryValidation.RegistryTypeMismatch.selector, other.serviceRegistry)
        );
        _verify(standIn);
    }

    function test_verifierRefusesUnexpectedDependencies() public {
        MarketplaceRegistryValidation.Registries memory registries = _deployAndAccept();

        MockCanonicalIdentityRegistry otherIdentity = new MockCanonicalIdentityRegistry();
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistryIdentityMismatch.selector,
                registries.agentIndex,
                address(otherIdentity),
                address(identity)
            )
        );
        verifier.verify(registries, address(otherIdentity), address(sanctions), address(safe));

        MockSanctionsList otherOracle = new MockSanctionsList();
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.RegistrySanctionsOracleMismatch.selector,
                registries.agentIndex,
                address(otherOracle),
                address(sanctions)
            )
        );
        verifier.verify(registries, address(identity), address(otherOracle), address(safe));

        // Registries deployed for Base use Base USDC and do not verify as a Base Sepolia deployment.
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceRegistryValidation.ProviderRegistryTokenMismatch.selector, BASE_SEPOLIA_USDC, BASE_USDC
            )
        );
        _verify(registries);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceRegistryValidation.UnsupportedRegistryChain.selector, 1));
        _verify(registries);
    }

    // ------------------------------------------------------------------
    // Environment inputs
    // ------------------------------------------------------------------

    function test_runAndVerifyReadTheirEnvironmentInputs() public {
        // No other test reads or writes these variables, so parallel tests cannot interfere.
        _setEnv("IDENTITY_REGISTRY_ADDRESS", vm.toString(address(identity)));
        _setEnv("SANCTIONS_ORACLE_ADDRESS", vm.toString(address(sanctions)));
        _setEnv("MARKETPLACE_REGISTRIES_FINAL_ADMIN", vm.toString(address(safe)));
        _setEnv("MARKETPLACE_REGISTRIES_PAUSE_GUARDIAN", vm.toString(guardian));
        _setEnv("PROVIDER_REGISTRY_TREASURY", vm.toString(treasury));
        _setEnv("PROVIDER_REGISTRY_LISTING_FEE", vm.toString(LISTING_FEE));

        MarketplaceRegistryValidation.Registries memory registries;
        (
            registries.agentIndex,
            registries.validationRegistry,
            registries.providerRegistry,
            registries.serviceRegistry
        ) = script.run();
        _requireGenesisState(registries, BASE_USDC);

        _accept(registries);
        _setEnv("AGENT_INDEX_ADDRESS", vm.toString(registries.agentIndex));
        _setEnv("VALIDATION_REGISTRY_ADDRESS", vm.toString(registries.validationRegistry));
        _setEnv("PROVIDER_REGISTRY_ADDRESS", vm.toString(registries.providerRegistry));
        _setEnv("SERVICE_REGISTRY_ADDRESS", vm.toString(registries.serviceRegistry));
        (address agentIndexImplementation,,, address serviceRegistryImplementation) = verifier.run();
        assertEq(agentIndexImplementation, _implementation(registries.agentIndex));
        assertEq(serviceRegistryImplementation, _implementation(registries.serviceRegistry));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _checkGenesisState(uint256 chainId, address reviewedToken) private {
        vm.chainId(chainId);
        MarketplaceRegistryValidation.Registries memory registries = script.deploy(_config());
        _requireGenesisState(registries, reviewedToken);

        // The proxies are initialized exactly once, and the implementations never.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AgentIndex(registries.agentIndex).initialize(address(identity), address(sanctions), address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AgentIndex(_implementation(registries.agentIndex))
            .initialize(address(identity), address(sanctions), address(this));
    }

    function _requireGenesisState(MarketplaceRegistryValidation.Registries memory registries, address reviewedToken)
        private
        view
    {
        address deployer = _broadcaster();
        address[4] memory proxies = _list(registries);
        for (uint256 i = 0; i < proxies.length; i++) {
            Admin2StepUpgradeable registry = Admin2StepUpgradeable(proxies[i]);
            assertEq(registry.admin(), deployer);
            assertEq(registry.pendingAdmin(), address(safe));
            assertEq(registry.pauseGuardian(), guardian);
            assertTrue(registry.externalDependencyPaused());
            assertEq(address(ISanctionsGuard(proxies[i]).sanctionsOracle()), address(sanctions));
            assertTrue(_implementation(proxies[i]).code.length != 0);
        }

        assertEq(AgentIndex(registries.agentIndex).getIdentityRegistry(), address(identity));
        assertEq(ValidationRegistry(registries.validationRegistry).getIdentityRegistry(), address(identity));
        ProviderRegistry providers = ProviderRegistry(registries.providerRegistry);
        assertEq(address(providers.identity()), address(identity));
        assertEq(address(providers.usdc()), reviewedToken);
        assertEq(providers.treasury(), treasury);
        assertEq(providers.listingFee(), LISTING_FEE);
        ServiceRegistry services = ServiceRegistry(registries.serviceRegistry);
        assertEq(address(services.identity()), address(identity));
        assertEq(address(services.providerRegistry()), registries.providerRegistry);
    }

    function _checkHandoffEndsDeployerAuthority(uint256 chainId, address reviewedToken) private {
        vm.chainId(chainId);
        MarketplaceRegistryValidation.Registries memory registries = script.deploy(_config());
        address deployer = Admin2StepUpgradeable(registries.agentIndex).admin();
        assertEq(deployer, _broadcaster());

        _accept(registries);

        address[4] memory proxies = _list(registries);
        address newImplementation = address(new ValidationRegistry());
        for (uint256 i = 0; i < proxies.length; i++) {
            Admin2StepUpgradeable registry = Admin2StepUpgradeable(proxies[i]);
            assertEq(registry.admin(), address(safe));
            assertEq(registry.pendingAdmin(), address(0));
            assertFalse(registry.externalDependencyPaused());
            assertTrue(registry.pauseGuardian() != deployer);

            vm.startPrank(deployer);
            vm.expectRevert("not admin");
            registry.transferAdmin(deployer);
            vm.expectRevert("not pending admin");
            registry.acceptAdmin();
            vm.expectRevert("not admin");
            registry.setPauseGuardian(deployer);
            vm.expectRevert("not admin or guardian");
            registry.pauseExternalDependency();
            vm.expectRevert("not admin");
            registry.unpauseExternalDependency();
            vm.expectRevert("not admin");
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(newImplementation, "");
            vm.stopPrank();
        }

        vm.startPrank(deployer);
        vm.expectRevert("not admin");
        ProviderRegistry(registries.providerRegistry).setListingFee(0);
        vm.expectRevert("not admin");
        ProviderRegistry(registries.providerRegistry).setTreasury(deployer);
        vm.stopPrank();

        _checkRegistriesOperate(registries, reviewedToken);
    }

    /// @dev One provider goes through all four registries against the shared identity registry.
    function _checkRegistriesOperate(MarketplaceRegistryValidation.Registries memory registries, address reviewedToken)
        private
    {
        MockUSDC(reviewedToken).mint(provider, LISTING_FEE);
        vm.startPrank(provider);
        uint256 agentId = identity.register("ipfs://provider");
        MockUSDC(reviewedToken).approve(registries.providerRegistry, LISTING_FEE);
        ProviderRegistry(registries.providerRegistry).register(agentId);
        bytes32 serviceId = ServiceRegistry(registries.serviceRegistry)
            .registerService(agentId, "service", "1", "ipfs://service", address(0));
        AgentIndex(registries.agentIndex).claim(agentId);
        ValidationRegistry(registries.validationRegistry)
            .validationRequest(makeAddr("validator"), agentId, "ipfs://request", keccak256("request"));
        vm.stopPrank();

        assertEq(MockUSDC(reviewedToken).balanceOf(treasury), LISTING_FEE);
        assertTrue(ServiceRegistry(registries.serviceRegistry).isActive(serviceId));
        (uint256 resolved, bool found) = AgentIndex(registries.agentIndex).resolve(provider);
        assertTrue(found);
        assertEq(resolved, agentId);
        assertEq(ValidationRegistry(registries.validationRegistry).getAgentValidationCount(agentId), 1);
    }

    function _deployAndAccept() private returns (MarketplaceRegistryValidation.Registries memory registries) {
        registries = script.deploy(_config());
        _accept(registries);
    }

    /// @dev The Safe's acceptance batch: accept administration, then activate.
    function _accept(MarketplaceRegistryValidation.Registries memory registries) private {
        address[4] memory proxies = _list(registries);
        vm.startPrank(address(safe));
        for (uint256 i = 0; i < proxies.length; i++) {
            Admin2StepUpgradeable(proxies[i]).acceptAdmin();
            Admin2StepUpgradeable(proxies[i]).unpauseExternalDependency();
        }
        vm.stopPrank();
    }

    function _verify(MarketplaceRegistryValidation.Registries memory registries) private view {
        verifier.verify(registries, address(identity), address(sanctions), address(safe));
    }

    function _config() private view returns (DeployMarketplaceRegistries.Config memory config) {
        config.identityRegistry = address(identity);
        config.sanctionsOracle = address(sanctions);
        config.finalAdmin = address(safe);
        config.pauseGuardian = guardian;
        config.treasury = treasury;
        config.listingFee = LISTING_FEE;
    }

    /// @dev `vm.startBroadcast()` without a key signs as the configured sender, which is the transaction origin here.
    function _broadcaster() private view returns (address) {
        return tx.origin;
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _list(MarketplaceRegistryValidation.Registries memory registries)
        private
        pure
        returns (address[4] memory)
    {
        return [
            registries.agentIndex,
            registries.validationRegistry,
            registries.providerRegistry,
            registries.serviceRegistry
        ];
    }

    function _copy(MarketplaceRegistryValidation.Registries memory registries)
        private
        pure
        returns (MarketplaceRegistryValidation.Registries memory)
    {
        return MarketplaceRegistryValidation.Registries({
            agentIndex: registries.agentIndex,
            validationRegistry: registries.validationRegistry,
            providerRegistry: registries.providerRegistry,
            serviceRegistry: registries.serviceRegistry
        });
    }

    function _safe(uint256 threshold, address[] memory owners) private returns (ThresholdSafeStub) {
        address[] memory modules = new address[](0);
        return
            new ThresholdSafeStub(address(safeSingleton), threshold, owners, modules, address(0), address(safeHandler));
    }

    function _owners(uint256 count) private returns (address[] memory owners) {
        owners = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            owners[i] = makeAddr(string.concat("safe-owner-", vm.toString(i)));
        }
    }

    function _setEnv(string memory name, string memory value) private {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(name, value);
    }
}
