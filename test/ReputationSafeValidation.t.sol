// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployReputationStorage} from "../script/DeployReputationStorage.s.sol";
import {ReputationSafeValidation} from "../script/ReputationSafeValidation.sol";
import {
    DeployReputationStorageHarness,
    ReputationSafeFallbackHandlerStub,
    ReputationSafeSingletonStub,
    ThresholdSafeStub
} from "./helpers/ReputationDeploymentHarness.sol";

contract AbiOnlySafeSpoof {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}

contract ReputationSafeValidationTest is Test {
    DeployReputationStorageHarness private validator;
    ReputationSafeSingletonStub private singleton;
    ReputationSafeFallbackHandlerStub private handler;

    function setUp() public {
        validator = new DeployReputationStorageHarness();
        singleton = new ReputationSafeSingletonStub();
        handler = new ReputationSafeFallbackHandlerStub();
        validator.setReviewedSafeContracts(address(singleton), address(handler));
    }

    function test_acceptsMinimumSafeControlsWithoutOwnerProfile() public {
        ThresholdSafeStub safe = _safe(2, _owners(), _empty(), address(0), address(handler));
        validator.validateGovernance(_config(address(safe)));

        address[] memory differentOwners = _owners();
        differentOwners[0] = makeAddr("independently-reviewed-owner");
        safe.setOwners(differentOwners);
        validator.validateGovernance(_config(address(safe)));
    }

    function test_rejectsAbiOnlySpoofAndWrongSingleton() public {
        AbiOnlySafeSpoof spoof = new AbiOnlySafeSpoof();
        vm.expectPartialRevert(ReputationSafeValidation.SafeProxyCodeHashMismatch.selector);
        validator.validateGovernance(_config(address(spoof)));

        ThresholdSafeStub safe = _defaultSafe();
        safe.setSingleton(address(new ReputationSafeSingletonStub()));
        vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonMismatch.selector);
        validator.validateGovernance(_config(address(safe)));
    }

    function test_rejectsSingletonRuntimeChange() public {
        ThresholdSafeStub safe = _defaultSafe();
        vm.etch(address(singleton), hex"00");
        vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonCodeHashMismatch.selector);
        validator.validateGovernance(_config(address(safe)));
    }

    function test_requiresThresholdOfAtLeastTwo() public {
        ThresholdSafeStub safe = _defaultSafe();
        safe.setThreshold(1);
        vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.InvalidSafeThreshold.selector, 1, 2));
        validator.validateGovernance(_config(address(safe)));

        safe.setThreshold(3);
        vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.InvalidSafeThreshold.selector, 3, 2));
        validator.validateGovernance(_config(address(safe)));

        address[] memory threeOwners = new address[](3);
        threeOwners[0] = makeAddr("owner-one");
        threeOwners[1] = makeAddr("owner-two");
        threeOwners[2] = makeAddr("owner-three");
        safe.setOwners(threeOwners);
        validator.validateGovernance(_config(address(safe)));
    }

    function test_requiresNonzeroUniqueOwners() public {
        ThresholdSafeStub safe = _defaultSafe();
        address[] memory owners = _owners();
        owners[1] = address(0);
        safe.setOwners(owners);
        vm.expectRevert(ReputationSafeValidation.InvalidSafeOwners.selector);
        validator.validateGovernance(_config(address(safe)));

        owners[1] = owners[0];
        safe.setOwners(owners);
        vm.expectRevert(ReputationSafeValidation.InvalidSafeOwners.selector);
        validator.validateGovernance(_config(address(safe)));
    }

    function test_requiresNoModules() public {
        ThresholdSafeStub safe = _defaultSafe();
        safe.setModules(_single(makeAddr("module")));
        vm.expectRevert(ReputationSafeValidation.InvalidSafeModules.selector);
        validator.validateGovernance(_config(address(safe)));
    }

    function test_requiresZeroGuardAndCanonicalHandler() public {
        ThresholdSafeStub safe = _defaultSafe();
        safe.setGuard(makeAddr("guard"));
        vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeGuard.selector);
        validator.validateGovernance(_config(address(safe)));

        safe = _defaultSafe();
        safe.setFallbackHandler(makeAddr("other-handler"));
        vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeFallbackHandler.selector);
        validator.validateGovernance(_config(address(safe)));

        safe = _defaultSafe();
        vm.etch(address(handler), bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(ReputationSafeValidation.SafeFallbackHandlerHasNoCode.selector, address(handler))
        );
        validator.validateGovernance(_config(address(safe)));
    }

    function _config(address safe) private returns (DeployReputationStorage.DeploymentConfig memory config) {
        config.admin = address(this);
        config.finalAdmin = safe;
        config.pauseGuardian = makeAddr("pause-guardian");
        config.orderSigner = makeAddr("order-signer");
    }

    function _defaultSafe() private returns (ThresholdSafeStub) {
        return _safe(2, _owners(), _empty(), address(0), address(handler));
    }

    function _safe(
        uint256 threshold,
        address[] memory owners,
        address[] memory modules,
        address guard,
        address fallbackHandler
    ) private returns (ThresholdSafeStub) {
        return new ThresholdSafeStub(address(singleton), threshold, owners, modules, guard, fallbackHandler);
    }

    function _owners() private returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = makeAddr("safe-owner-one");
        owners[1] = makeAddr("safe-owner-two");
    }

    function _single(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _empty() private pure returns (address[] memory values) {
        values = new address[](0);
    }
}
