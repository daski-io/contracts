// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface ICanonicalSafe {
    function setup(address[] calldata, uint256, address, bytes calldata, address, address, uint256, address payable)
        external;
    function nonce() external view returns (uint256);
    function changeThreshold(uint256) external;
    function enableModule(address) external;
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    ) external payable returns (bool);
}

/// @dev Canonical upstream compiled artifacts; no validator identities are overridden.
abstract contract CanonicalSafeFixture is Test {
    function _fixture(bool v150) internal view returns (string memory) {
        return vm.readFile(v150 ? "test/vectors/safe-1.5.0.json" : "test/vectors/safe-1.4.1.json");
    }

    function _canonicalSafe(bool v150) internal returns (address safe) {
        string memory fixture = _fixture(v150);
        address singleton = vm.parseJsonAddress(fixture, ".singletonAddress");
        address handler = vm.parseJsonAddress(fixture, ".handlerAddress");
        vm.etch(singleton, vm.parseJsonBytes(fixture, ".artifacts.SafeL2.runtime"));
        vm.etch(handler, vm.parseJsonBytes(fixture, ".artifacts.CompatibilityFallbackHandler.runtime"));
        bytes memory creation =
            abi.encodePacked(vm.parseJsonBytes(fixture, ".artifacts.SafeProxy.creationCode"), abi.encode(singleton));
        assembly ("memory-safe") { safe := create(0, add(creation, 32), mload(creation)) }
        require(safe != address(0), "Safe creation failed");
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            owners[i] = vm.addr(101 + i);
        }
        ICanonicalSafe(safe).setup(owners, 2, address(0), bytes(""), handler, address(0), 0, payable(address(0)));
    }

    /// @dev Exercise real two-signature execution and nonce handling on both Safe versions.
    function _executeSafe(address safe, address target, bytes memory data) internal {
        bytes memory signatures = _signatures(safe, target, data);
        assertTrue(
            ICanonicalSafe(safe)
                .execTransaction(target, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
    }

    function _signatures(address safe, address target, bytes memory data) private view returns (bytes memory) {
        bytes32 digest = ICanonicalSafe(safe)
            .getTransactionHash(target, 0, data, 0, 0, 0, 0, address(0), address(0), ICanonicalSafe(safe).nonce());
        uint256 first = vm.addr(101) < vm.addr(102) ? 101 : 102;
        uint256 second = first == 101 ? 102 : 101;
        return abi.encodePacked(_signature(first, digest), _signature(second, digest));
    }

    function _signature(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
