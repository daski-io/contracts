// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReputationSafeValidation} from "../script/ReputationSafeValidation.sol";
import {CanonicalSafeFixture, ICanonicalSafe} from "./helpers/CanonicalSafeFixture.sol";

contract CanonicalSafeValidator is ReputationSafeValidation {
    function validate(address safe) external view {
        _validateSafe(safe);
    }
}

contract CanonicalSafeValidationTest is CanonicalSafeFixture {
    CanonicalSafeValidator private validator;

    function setUp() public {
        validator = new CanonicalSafeValidator();
        vm.chainId(8453);
    }

    function test_acceptsBothVersionsOnBothBaseChains() public {
        for (uint256 version; version < 2; ++version) {
            address safe = _canonicalSafe(version == 1);
            vm.chainId(8453);
            validator.validate(safe);
            vm.chainId(84532);
            validator.validate(safe);
            vm.chainId(1);
            vm.expectRevert(abi.encodeWithSelector(ReputationSafeValidation.UnsupportedSafeChain.selector, 1));
            validator.validate(safe);
        }
    }

    function test_rejectsUnknownProxyRuntimeAndMixedVersions() public {
        for (uint256 version; version < 2; ++version) {
            address candidate = _canonicalSafe(version == 1);
            bytes memory unreviewedCode = abi.encodePacked(candidate.code, hex"00");
            vm.etch(candidate, unreviewedCode);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ReputationSafeValidation.UnreviewedSafeProxyCodeHash.selector, keccak256(unreviewedCode)
                )
            );
            validator.validate(candidate);
        }

        address safe = _canonicalSafe(true);
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(0x29fcB43b46531BcA003ddC8FCB67FFE91900C762))));
        vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonMismatch.selector);
        validator.validate(safe);

        safe = _canonicalSafe(false);
        vm.store(safe, bytes32(0), bytes32(uint256(uint160(0xEdd160fEBBD92E350D4D398fb636302fccd67C7e))));
        vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonMismatch.selector);
        validator.validate(safe);
    }

    function test_rejectsChangedSingletonAndHandlerCodeForBothVersions() public {
        for (uint256 version; version < 2; ++version) {
            address safe = _canonicalSafe(version == 1);
            string memory fixture = _fixture(version == 1);
            address singleton = vm.parseJsonAddress(fixture, ".singletonAddress");
            address handler = vm.parseJsonAddress(fixture, ".handlerAddress");
            bytes memory code = singleton.code;
            vm.etch(singleton, hex"00");
            vm.expectPartialRevert(ReputationSafeValidation.SafeSingletonCodeHashMismatch.selector);
            validator.validate(safe);
            vm.etch(singleton, code);
            vm.etch(handler, hex"00");
            vm.expectPartialRevert(ReputationSafeValidation.SafeFallbackHandlerCodeHashMismatch.selector);
            validator.validate(safe);
        }
    }

    function test_rejectsWeakThresholdAndModulesForBothVersions() public {
        for (uint256 version; version < 2; ++version) {
            address safe = _canonicalSafe(version == 1);
            vm.prank(safe);
            ICanonicalSafe(safe).changeThreshold(1);
            vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeThreshold.selector);
            validator.validate(safe);
            vm.prank(safe);
            ICanonicalSafe(safe).changeThreshold(2);
            vm.prank(safe);
            ICanonicalSafe(safe).enableModule(makeAddr("unreviewed-module"));
            vm.expectRevert(ReputationSafeValidation.InvalidSafeModules.selector);
            validator.validate(safe);
        }
    }

    function test_rejectsBothGuardSlotsForBothVersions() public {
        for (uint256 version; version < 2; ++version) {
            address safe = _canonicalSafe(version == 1);
            bytes32 guardSlot = keccak256("guard_manager.guard.address");
            vm.store(safe, guardSlot, bytes32(uint256(123)));
            vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeGuard.selector);
            validator.validate(safe);
            vm.store(safe, guardSlot, bytes32(0));
            vm.store(safe, keccak256("module_manager.module_guard.address"), bytes32(uint256(123)));
            vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeModuleGuard.selector);
            validator.validate(safe);
        }
    }

    function test_rejectsCrossVersionFallbackHandlers() public {
        for (uint256 version; version < 2; ++version) {
            address safe = _canonicalSafe(version == 1);
            address wrong = vm.parseJsonAddress(_fixture(version == 0), ".handlerAddress");
            vm.store(safe, keccak256("fallback_manager.handler.address"), bytes32(uint256(uint160(wrong))));
            vm.expectPartialRevert(ReputationSafeValidation.InvalidSafeFallbackHandler.selector);
            validator.validate(safe);
        }
    }
}
