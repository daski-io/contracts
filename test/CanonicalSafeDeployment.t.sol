// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployMarketplaceRegistries} from "../script/DeployMarketplaceRegistries.s.sol";
import {VerifyMarketplaceRegistries} from "../script/VerifyMarketplaceRegistries.s.sol";
import {DeployReputationStorage} from "../script/DeployReputationStorage.s.sol";
import {MarketplaceRegistryValidation} from "../script/MarketplaceRegistryValidation.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";
import {IEAS} from "../src/interfaces/IEAS.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {CanonicalSafeFixture} from "./helpers/CanonicalSafeFixture.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEAS} from "./helpers/MockEAS.sol";

// These adapters expose production helpers without overriding any Safe identities.
// Configuration is passed directly: vm.setEnv would race with other script tests.
contract CanonicalMarketplaceDeployment is DeployMarketplaceRegistries {
    function deploy(Config memory config) external returns (Registries memory) {
        return _deploy(config);
    }
}

contract CanonicalMarketplaceVerification is VerifyMarketplaceRegistries {
    function verify(Registries memory registries, address identity, address sanctions, address safe) external view {
        _verify(registries, identity, sanctions, safe);
    }
}

contract CanonicalReputationDeployment is DeployReputationStorage {
    function deploy(DeploymentConfig memory config, uint256 key) external returns (address proxy) {
        (proxy,,) = _deploy(config, key);
    }
}

contract CanonicalSafeDeploymentTest is CanonicalSafeFixture {
    function test_v141DeploymentAndSignedHandoffOnBase() public {
        _deployAndHandoff(false, 8453);
    }

    function test_v150DeploymentAndSignedHandoffOnBase() public {
        _deployAndHandoff(true, 8453);
    }

    function test_v141DeploymentAndSignedHandoffOnBaseSepolia() public {
        _deployAndHandoff(false, 84532);
    }

    function test_v150DeploymentAndSignedHandoffOnBaseSepolia() public {
        _deployAndHandoff(true, 84532);
    }

    function _deployAndHandoff(bool v150, uint256 chainId) private {
        vm.chainId(chainId);
        address safe = _canonicalSafe(v150);
        DeployMarketplaceRegistries.Config memory config = DeployMarketplaceRegistries.Config({
            identityRegistry: address(new MockCanonicalIdentityRegistry()),
            sanctionsOracle: address(new MockSanctionsList()),
            finalAdmin: safe,
            pauseGuardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            listingFee: 1000000
        });
        address token =
            chainId == 8453 ? 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 : 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        vm.etch(token, address(new MockUSDC()).code);
        MarketplaceRegistryValidation.Registries memory registries = new CanonicalMarketplaceDeployment().deploy(config);
        address[4] memory proxies = [
            registries.agentIndex,
            registries.validationRegistry,
            registries.providerRegistry,
            registries.serviceRegistry
        ];
        for (uint256 i; i < 4; ++i) {
            _handoff(safe, proxies[i]);
        }
        new CanonicalMarketplaceVerification().verify(registries, config.identityRegistry, config.sanctionsOracle, safe);
        _deployReputation(config, registries, token);
    }

    function _deployReputation(
        DeployMarketplaceRegistries.Config memory config,
        MarketplaceRegistryValidation.Registries memory registries,
        address token
    ) private {
        CanonicalReputationDeployment script = new CanonicalReputationDeployment();
        address eas = script.canonicalEAS(block.chainid);
        address schemaRegistry = script.canonicalSchemaRegistry(block.chainid);
        bytes memory easCode = address(new MockEAS()).code;
        vm.etch(eas, easCode);
        vm.etch(schemaRegistry, easCode);
        vm.mockCall(eas, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(schemaRegistry));
        // Public synthetic fixture key used only inside the local test VM.
        uint256 key = 0xA11CE;
        DeployReputationStorage.DeploymentConfig memory reputation;
        reputation.admin = vm.addr(key);
        reputation.finalAdmin = config.finalAdmin;
        reputation.pauseGuardian = config.pauseGuardian;
        reputation.orderSigner = makeAddr("order-signer");
        reputation.identityRegistry = config.identityRegistry;
        reputation.providerRegistry = registries.providerRegistry;
        reputation.serviceRegistry = registries.serviceRegistry;
        reputation.sanctionsOracle = config.sanctionsOracle;
        reputation.canonicalToken = token;
        reputation.eas = eas;
        address proxy = script.deploy(reputation, key);
        assertTrue(ReputationStorage(proxy).isConfigured());
        _handoff(config.finalAdmin, proxy);
    }

    function _handoff(address safe, address proxy) private {
        Admin2StepUpgradeable governed = Admin2StepUpgradeable(proxy);
        address bootstrap = governed.admin();
        assertEq(governed.pendingAdmin(), safe);
        assertTrue(governed.externalDependencyPaused());
        _executeSafe(safe, proxy, abi.encodeCall(Admin2StepUpgradeable.acceptAdmin, ()));
        assertEq(governed.admin(), safe);
        assertEq(governed.pendingAdmin(), address(0));
        vm.prank(bootstrap);
        vm.expectRevert("not admin");
        governed.unpauseExternalDependency();
        _executeSafe(safe, proxy, abi.encodeCall(Admin2StepUpgradeable.unpauseExternalDependency, ()));
        assertFalse(governed.externalDependencyPaused());
    }
}
