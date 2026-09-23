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
        address identity = address(new MockCanonicalIdentityRegistry());
        address sanctions = address(new MockSanctionsList());
        address token =
            chainId == 8453 ? 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 : 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        vm.etch(token, address(new MockUSDC()).code);
        _env("IDENTITY_REGISTRY_ADDRESS", identity);
        _env("SANCTIONS_ORACLE_ADDRESS", sanctions);
        _env("MARKETPLACE_REGISTRIES_FINAL_ADMIN", safe);
        _env("MARKETPLACE_REGISTRIES_PAUSE_GUARDIAN", makeAddr("guardian"));
        _env("PROVIDER_REGISTRY_TREASURY", makeAddr("treasury"));
        _setEnv("PROVIDER_REGISTRY_LISTING_FEE", "1000000");
        // Production script and validator, including preflight and post-deployment checks.
        (address agent, address validation, address provider, address service) = new DeployMarketplaceRegistries().run();
        address[4] memory registries = [agent, validation, provider, service];
        for (uint256 i; i < 4; ++i) {
            _handoff(safe, registries[i]);
        }

        _env("AGENT_INDEX_ADDRESS", agent);
        _env("VALIDATION_REGISTRY_ADDRESS", validation);
        _env("PROVIDER_REGISTRY_ADDRESS", provider);
        _env("SERVICE_REGISTRY_ADDRESS", service);
        new VerifyMarketplaceRegistries().run();

        DeployReputationStorage reputationScript = new DeployReputationStorage();
        address eas = reputationScript.canonicalEAS(chainId);
        address schemaRegistry = reputationScript.canonicalSchemaRegistry(chainId);
        bytes memory easCode = address(new MockEAS()).code;
        vm.etch(eas, easCode);
        vm.etch(schemaRegistry, easCode);
        vm.mockCall(eas, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(schemaRegistry));
        // Public synthetic fixture key used only inside the local test VM.
        _setEnv("STANDARD_REPUTATION_ADMIN_PRIVATE_KEY", vm.toString(uint256(0xA11CE)));
        _env("STANDARD_REPUTATION_FINAL_ADMIN", safe);
        _env("STANDARD_REPUTATION_PAUSE_GUARDIAN", makeAddr("guardian"));
        _env("STANDARD_REPUTATION_ORDER_SIGNER", makeAddr("order-signer"));
        _env("STANDARD_RAIL_CANONICAL_TOKEN", token);
        (address reputation,,) = reputationScript.run();
        assertTrue(ReputationStorage(reputation).isConfigured());
        _handoff(safe, reputation);
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

    function _env(string memory name, address value) private {
        _setEnv(name, vm.toString(value));
    }

    function _setEnv(string memory name, string memory value) private {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(name, value);
    }
}
