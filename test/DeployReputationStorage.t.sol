// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployReputationStorage} from "../script/DeployReputationStorage.s.sol";
import {ReputationSafeValidation} from "../script/ReputationSafeValidation.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {
    DeployReputationStorageHarness,
    ReputationSafeFallbackHandlerStub,
    ReputationSafeSingletonStub,
    ThresholdSafeStub
} from "./helpers/ReputationDeploymentHarness.sol";
import {
    ReputationIdentityDependencyStub,
    ReputationProviderDependencyStub,
    ReputationServiceDependencyStub,
    ReputationUsdcDependencyStub
} from "./helpers/ReputationDependencyStubs.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract DeployReputationStorageTest is Test {
    DeployReputationStorageHarness private script;
    ReputationSafeSingletonStub private safeSingleton;
    ReputationSafeFallbackHandlerStub private safeHandler;

    function setUp() public {
        script = new DeployReputationStorageHarness();
        safeSingleton = new ReputationSafeSingletonStub();
        safeHandler = new ReputationSafeFallbackHandlerStub();
        script.setReviewedSafeContracts(address(safeSingleton), address(safeHandler));
    }

    function test_governanceRequiresReviewedSafeAndIndependentGuardian() public {
        ThresholdSafeStub safe = _safe(2);
        DeployReputationStorage.DeploymentConfig memory config = _baseConfig(address(safe));
        script.validateGovernance(config);

        config.finalAdmin = makeAddr("eoa-admin");
        vm.expectRevert(
            abi.encodeWithSelector(ReputationSafeValidation.FinalAdminMustBeReviewedSafe.selector, config.finalAdmin)
        );
        script.validateGovernance(config);

        config = _baseConfig(address(_safe(1)));
        vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.InvalidSafeThreshold.selector, 1, 2));
        script.validateGovernance(config);

        config = _baseConfig(address(safe));
        address[4] memory invalidGuardians = [address(0), config.admin, config.finalAdmin, config.orderSigner];
        for (uint256 i = 0; i < invalidGuardians.length; i++) {
            config.pauseGuardian = invalidGuardians[i];
            vm.expectRevert(DeployReputationStorage.InvalidPauseGuardian.selector);
            script.validateGovernance(config);
        }
    }

    function test_handoffReadinessBlocksBootstrapAdminActivation() public {
        ThresholdSafeStub safe = _safe(2);
        DeployReputationStorage.DeploymentConfig memory config = _baseConfig(address(safe));
        MockEAS localEAS = MockEAS(config.eas);
        ReputationStorage reputation = _reputation(config);
        bytes32 outcomeSchema = localEAS.register("bytes32 orderKey,uint8 outcome", address(reputation), false);
        bytes32 confirmationSchema = localEAS.register("bytes32 orderKey,uint8 confirmation", address(reputation), true);
        reputation.setPauseGuardian(config.pauseGuardian);
        reputation.setEAS(config.eas);
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        reputation.transferAdmin(address(safe));

        vm.expectRevert(DeployReputationStorage.DeploymentNotReady.selector);
        script.requireHandoffReady(reputation, config, outcomeSchema, confirmationSchema);

        reputation.pauseExternalDependency();
        script.requireHandoffReady(reputation, config, outcomeSchema, confirmationSchema);
        ReputationProviderDependencyStub(config.providerRegistry).setSanctionsOracle(makeAddr("wrong-oracle"));
        vm.expectRevert("provider sanctions mismatch");
        script.requireHandoffReady(reputation, config, outcomeSchema, confirmationSchema);
        ReputationProviderDependencyStub(config.providerRegistry).setSanctionsOracle(config.sanctionsOracle);
        vm.expectRevert("admin transfer pending");
        reputation.unpauseExternalDependency();

        safe.acceptReputationAdmin(reputation);
        assertEq(reputation.admin(), address(safe));
        assertTrue(reputation.externalDependencyPaused());
        safe.activateReputation(reputation);
        assertFalse(reputation.externalDependencyPaused());
    }

    function _baseConfig(address finalAdmin) private returns (DeployReputationStorage.DeploymentConfig memory config) {
        ReputationIdentityDependencyStub identity = new ReputationIdentityDependencyStub();
        ReputationUsdcDependencyStub token = new ReputationUsdcDependencyStub();
        MockSanctionsList sanctions = new MockSanctionsList();
        ReputationProviderDependencyStub provider =
            new ReputationProviderDependencyStub(address(identity), address(token), address(sanctions));
        ReputationServiceDependencyStub service =
            new ReputationServiceDependencyStub(address(identity), address(provider), address(sanctions));
        config = DeployReputationStorage.DeploymentConfig({
            admin: address(this),
            finalAdmin: finalAdmin,
            pauseGuardian: makeAddr("pause-guardian"),
            orderSigner: makeAddr("order-signer"),
            identityRegistry: address(identity),
            providerRegistry: address(provider),
            serviceRegistry: address(service),
            sanctionsOracle: address(sanctions),
            canonicalToken: address(token),
            eas: address(new MockEAS())
        });
    }

    function _reputation(DeployReputationStorage.DeploymentConfig memory config) private returns (ReputationStorage) {
        ReputationStorage implementation = new ReputationStorage();
        return ReputationStorage(
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
    }

    function _safe(uint256 threshold) private returns (ThresholdSafeStub) {
        address[] memory modules = new address[](0);
        return
            new ThresholdSafeStub(
                address(safeSingleton), threshold, _owners(), modules, address(0), address(safeHandler)
            );
    }

    function _owners() private returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = makeAddr("safe-owner-one");
        owners[1] = makeAddr("safe-owner-two");
    }
}
