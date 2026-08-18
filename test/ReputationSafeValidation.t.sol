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

    function getOwners() external pure returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = address(0xA1);
        owners[1] = address(0xA2);
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

    function test_acceptsExactUnorderedOwnerAndModuleSets() public {
        address moduleOne = makeAddr("module-one");
        address moduleTwo = makeAddr("module-two");
        address[] memory actualModules = _addresses(moduleOne, moduleTwo);
        ThresholdSafeStub safe = _safe(2, _owners(), actualModules, address(0), address(handler));

        address[] memory expectedOwners = _addresses(_owners()[1], _owners()[0]);
        address[] memory expectedModules = _addresses(moduleTwo, moduleOne);
        validator.validateGovernance(_config(address(safe), _profile(expectedOwners, 2, expectedModules)));
    }

    function test_rejectsAbiOnlySafeSpoofAndWrongSingleton() public {
        AbiOnlySafeSpoof spoof = new AbiOnlySafeSpoof();
        vm.expectPartialRevert(ReputationSafeValidation.SafeProxyCodeHashMismatch.selector);
        validator.validateGovernance(_config(address(spoof), _defaultProfile()));

        ThresholdSafeStub safe = _defaultSafe();
        ReputationSafeSingletonStub otherSingleton = new ReputationSafeSingletonStub();
        safe.setSingleton(address(otherSingleton));
        vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonMismatch.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));
    }

    function test_rejectsSingletonAndHandlerRuntimeChanges() public {
        ThresholdSafeStub safe = _defaultSafe();
        vm.etch(address(singleton), hex"00");
        vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonCodeHashMismatch.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        setUp();
        safe = _defaultSafe();
        vm.etch(address(handler), hex"00");
        vm.expectPartialRevert(ReputationSafeValidation.SafeFallbackHandlerCodeHashMismatch.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));
    }

    function test_rejectsOwnerThresholdAndDuplicateDrift() public {
        ThresholdSafeStub safe = _defaultSafe();
        address[] memory extraOwners = new address[](3);
        extraOwners[0] = _owners()[0];
        extraOwners[1] = _owners()[1];
        extraOwners[2] = makeAddr("extra-owner");
        safe.setOwners(extraOwners);
        vm.expectRevert(ReputationSafeValidation.InvalidSafeOwners.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        safe = _defaultSafe();
        safe.setOwners(_addresses(_owners()[0], _owners()[0]));
        vm.expectPartialRevert(ReputationSafeValidation.DuplicateSafeAddress.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        safe = _defaultSafe();
        safe.setThreshold(1);
        vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.InvalidSafeThreshold.selector, 1, 2));
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        ReputationSafeValidation.SafeProfile memory duplicateExpected = _defaultProfile();
        duplicateExpected.owners = _addresses(_owners()[0], _owners()[0]);
        safe = _defaultSafe();
        vm.expectPartialRevert(ReputationSafeValidation.DuplicateSafeAddress.selector);
        validator.validateGovernance(_config(address(safe), duplicateExpected));
    }

    function test_rejectsExtraAndDuplicateModulesIncludingEmptyExpectedSet() public {
        address moduleOne = makeAddr("module-one");
        address moduleTwo = makeAddr("module-two");
        ThresholdSafeStub safe = _safe(2, _owners(), _single(moduleOne), address(0), address(handler));
        vm.expectRevert(ReputationSafeValidation.InvalidSafeModules.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        address[] memory duplicates = _addresses(moduleOne, moduleOne);
        safe = _safe(2, _owners(), duplicates, address(0), address(handler));
        ReputationSafeValidation.SafeProfile memory profile = _defaultProfile();
        profile.modules = _addresses(moduleOne, moduleTwo);
        vm.expectPartialRevert(ReputationSafeValidation.DuplicateSafeAddress.selector);
        validator.validateGovernance(_config(address(safe), profile));

        safe = _safe(2, _owners(), _addresses(moduleOne, moduleTwo), address(0), address(handler));
        profile.modules = duplicates;
        vm.expectPartialRevert(ReputationSafeValidation.DuplicateSafeAddress.selector);
        validator.validateGovernance(_config(address(safe), profile));
    }

    function test_rejectsUnexpectedGuardAndFallbackHandler() public {
        address guard = makeAddr("guard");
        ThresholdSafeStub safe = _safe(2, _owners(), _empty(), guard, address(handler));
        vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeGuard.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        safe = _defaultSafe();
        safe.setFallbackHandler(makeAddr("other-handler"));
        vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeFallbackHandler.selector);
        validator.validateGovernance(_config(address(safe), _defaultProfile()));

        ReputationSafeValidation.SafeProfile memory profile = _defaultProfile();
        profile.fallbackHandler = makeAddr("unreviewed-handler");
        safe = _defaultSafe();
        vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeFallbackHandler.selector);
        validator.validateGovernance(_config(address(safe), profile));
    }

    function _config(address safe, ReputationSafeValidation.SafeProfile memory profile)
        private
        returns (DeployReputationStorage.DeploymentConfig memory config)
    {
        config.admin = address(this);
        config.finalAdmin = safe;
        config.pauseGuardian = makeAddr("pause-guardian");
        config.orderSigner = makeAddr("order-signer");
        config.safeProfile = profile;
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

    function _defaultProfile() private returns (ReputationSafeValidation.SafeProfile memory) {
        return _profile(_owners(), 2, _empty());
    }

    function _profile(address[] memory owners, uint256 threshold, address[] memory modules)
        private
        view
        returns (ReputationSafeValidation.SafeProfile memory profile)
    {
        profile = ReputationSafeValidation.SafeProfile({
            singleton: address(singleton),
            owners: owners,
            threshold: threshold,
            modules: modules,
            guard: address(0),
            fallbackHandler: address(handler)
        });
    }

    function _owners() private returns (address[] memory) {
        return _addresses(makeAddr("safe-owner-one"), makeAddr("safe-owner-two"));
    }

    function _single(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _addresses(address first, address second) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = first;
        values[1] = second;
    }

    function _empty() private pure returns (address[] memory values) {
        values = new address[](0);
    }
}
