// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISafe, SafeDeployment} from "../script/SafeDeployment.sol";

contract SafeValidationHarness {
    function validate(address safe, SafeDeployment.Profile calldata profile) external view {
        SafeDeployment.validateSafeProfile(safe, profile);
    }
}

contract SafeDeploymentTest is Test {
    bytes internal constant SAFE_PROXY_RUNTIME =
        hex"608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033";

    SafeValidationHarness internal harness;
    address internal safe = makeAddr("safe");
    address internal owner = makeAddr("owner");

    function setUp() public {
        harness = new SafeValidationHarness();
        vm.etch(safe, SAFE_PROXY_RUNTIME);
        vm.mockCall(safe, abi.encodeCall(ISafe.masterCopy, ()), abi.encode(SafeDeployment.SAFE_L2_SINGLETON));
    }

    function test_rejectsCorrectProxyWithWrongOwners() public {
        _mockOwners(new address[](0));

        vm.expectRevert("wrong Safe owner count");
        harness.validate(safe, _profile(1, new address[](0), address(0)));
    }

    function test_rejectsCorrectProxyWithWrongThreshold() public {
        _mockOwners(_singleAddress(owner));
        vm.mockCall(safe, abi.encodeCall(ISafe.getThreshold, ()), abi.encode(uint256(2)));

        vm.expectRevert("wrong Safe threshold");
        harness.validate(safe, _profile(1, new address[](0), address(0)));
    }

    function test_rejectsCorrectProxyWithUnexpectedModule() public {
        _mockOwners(_singleAddress(owner));
        vm.mockCall(safe, abi.encodeCall(ISafe.getThreshold, ()), abi.encode(uint256(1)));
        address[] memory liveModules = _singleAddress(makeAddr("module"));
        vm.mockCall(
            safe, abi.encodeCall(ISafe.getModulesPaginated, (address(0x1), 1)), abi.encode(liveModules, address(0x1))
        );

        vm.expectRevert("wrong Safe module count");
        harness.validate(safe, _profile(1, new address[](0), address(0)));
    }

    function test_rejectsCorrectProxyWithUnexpectedGuard() public {
        _mockBaseProfile();
        _mockStorage(uint256(keccak256("guard_manager.guard.address")), makeAddr("guard"));

        vm.expectRevert("wrong Safe guard");
        harness.validate(safe, _profile(1, new address[](0), address(0)));
    }

    function test_rejectsCorrectProxyWithWrongFallbackHandler() public {
        _mockBaseProfile();
        _mockStorage(uint256(keccak256("guard_manager.guard.address")), address(0));
        _mockStorage(uint256(keccak256("fallback_manager.handler.address")), makeAddr("fallback"));

        vm.expectRevert("wrong Safe fallback handler");
        harness.validate(safe, _profile(1, new address[](0), address(0)));
    }

    function test_rejectsOneOfOneReleaseCandidate() public {
        _mockBaseProfile();
        _mockStorage(uint256(keccak256("guard_manager.guard.address")), address(0));
        _mockStorage(
            uint256(keccak256("fallback_manager.handler.address")), SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER
        );
        SafeDeployment.Profile memory profile = _profile(1, new address[](0), address(0));
        profile.releaseCandidate = true;

        vm.expectRevert("release governance requires >=2 owners and threshold >=2");
        harness.validate(safe, profile);
    }

    function _mockBaseProfile() internal {
        _mockOwners(_singleAddress(owner));
        vm.mockCall(safe, abi.encodeCall(ISafe.getThreshold, ()), abi.encode(uint256(1)));
        vm.mockCall(
            safe,
            abi.encodeCall(ISafe.getModulesPaginated, (address(0x1), 1)),
            abi.encode(new address[](0), address(0x1))
        );
    }

    function _mockOwners(address[] memory liveOwners) internal {
        vm.mockCall(safe, abi.encodeCall(ISafe.getOwners, ()), abi.encode(liveOwners));
        vm.mockCall(safe, abi.encodeCall(ISafe.isOwner, (owner)), abi.encode(liveOwners.length == 1));
    }

    function _mockStorage(uint256 slot, address value) internal {
        bytes memory stored = abi.encode(bytes32(uint256(uint160(value))));
        vm.mockCall(safe, abi.encodeCall(ISafe.getStorageAt, (slot, 1)), abi.encode(stored));
    }

    function _profile(uint256 threshold, address[] memory modules, address guard)
        internal
        view
        returns (SafeDeployment.Profile memory)
    {
        return SafeDeployment.Profile({
            owners: _singleAddress(owner),
            threshold: threshold,
            modules: modules,
            guard: guard,
            fallbackHandler: SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER,
            releaseCandidate: false
        });
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
