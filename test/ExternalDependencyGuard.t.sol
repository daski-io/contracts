// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";

contract ExternalDependencyGuardHarness is Admin2StepUpgradeable {
    uint256 public calls;

    function initialize(address admin_) external initializer {
        __Admin2Step_init(admin_, address(new AlwaysAllowedSanctionsList()));
    }

    function guardedCall() external whenExternalDependencyOperational {
        calls++;
    }
}

contract AlwaysAllowedSanctionsList {
    function isSanctioned(address) external pure returns (bool) {
        return false;
    }
}

contract ExternalDependencyGuardTest is Test {
    ExternalDependencyGuardHarness private guard;
    address private guardian = makeAddr("guardian");
    address private stranger = makeAddr("stranger");

    function setUp() public {
        guard = new ExternalDependencyGuardHarness();
        guard.initialize(address(this));
        guard.setPauseGuardian(guardian);
    }

    function test_guardianCanOnlyPause() public {
        vm.prank(guardian);
        guard.pauseExternalDependency();
        assertTrue(guard.externalDependencyPaused());

        vm.prank(guardian);
        vm.expectRevert("not admin");
        guard.unpauseExternalDependency();

        vm.prank(guardian);
        vm.expectRevert("not admin");
        guard.setPauseGuardian(stranger);
    }

    function test_guardedCallsFailClosedAndAdminCanRecover() public {
        vm.prank(guardian);
        guard.pauseExternalDependency();
        vm.expectRevert("external dependency paused");
        guard.guardedCall();

        guard.unpauseExternalDependency();
        guard.guardedCall();
        assertEq(guard.calls(), 1);
    }

    function test_zeroGuardianRequiresPausedState() public {
        vm.expectRevert("zero guardian while operational");
        guard.setPauseGuardian(address(0));

        guard.pauseExternalDependency();
        guard.setPauseGuardian(address(0));
        assertEq(guard.pauseGuardian(), address(0));
        vm.expectRevert("zero guardian");
        guard.unpauseExternalDependency();
    }

    function test_unauthorizedAccountCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert("not admin or guardian");
        guard.pauseExternalDependency();
    }
}
