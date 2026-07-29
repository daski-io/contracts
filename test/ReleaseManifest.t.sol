// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ReleaseBuildProfile} from "../script/ReleaseBuildProfile.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";

contract ReleaseTestImplementation is Admin2StepUpgradeable {
    function initialize() external initializer {}
}

contract ReleaseManifestHarness is ReleaseBuildProfile {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function validateSourceCommit(string calldata sourceCommit) external pure {
        _validateSourceCommit(sourceCommit);
    }

    function validateSchemaDefinitions(string calldata outcome, string calldata confirmation) external pure {
        _validateSchemaDefinitions(outcome, confirmation);
    }

    function validateRuntimeIdentities(
        address proxy,
        address implementation,
        bytes32 proxyHash,
        bytes32 implementationHash
    ) external view {
        require(proxy.codehash == proxyHash, "proxy runtime fingerprint mismatch");
        address actualImplementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(actualImplementation == implementation, "proxy implementation mismatch");
        require(implementation.codehash == implementationHash, "implementation runtime fingerprint mismatch");
        require(IERC1822Proxiable(implementation).proxiableUUID() == IMPLEMENTATION_SLOT, "implementation not UUPS");
    }
}

contract ReleaseManifestTest is Test {
    ReleaseManifestHarness private manifest;

    function setUp() public {
        manifest = new ReleaseManifestHarness();
    }

    function test_acceptsCanonicalBuildIdentityFields() public view {
        manifest.validateSourceCommit("0123456789abcdef0123456789abcdef01234567");
    }

    function test_rejectsUppercaseSourceCommit() public {
        vm.expectRevert("invalid source commit");
        manifest.validateSourceCommit("0123456789abcdef0123456789abcdef0123456A");
    }

    function test_rejectsMalformedSourceCommit() public {
        vm.expectRevert("invalid source commit");
        manifest.validateSourceCommit("0123456789abcdef0123456789abcdef0123456g");
    }

    function test_rejectsShortSourceCommit() public {
        vm.expectRevert("invalid source commit");
        manifest.validateSourceCommit("0123456789abcdef");
    }

    function test_rejectsZeroSourceCommit() public {
        vm.expectRevert("zero source commit");
        manifest.validateSourceCommit("0000000000000000000000000000000000000000");
    }

    function test_acceptsCanonicalSchemaDefinitions() public view {
        manifest.validateSchemaDefinitions("uint256 paymentId,uint8 outcome", "uint256 paymentId,uint8 confirmation");
    }

    function test_rejectsMismatchedOutcomeDefinition() public {
        vm.expectRevert("wrong manifest outcome schema");
        manifest.validateSchemaDefinitions("uint256 paymentId,uint256 outcome", "uint256 paymentId,uint8 confirmation");
    }

    function test_rejectsMismatchedConfirmationDefinition() public {
        vm.expectRevert("wrong manifest confirmation schema");
        manifest.validateSchemaDefinitions("uint256 paymentId,uint8 outcome", "uint256 paymentId,uint256 confirmation");
    }

    function test_acceptsMatchingProxyImplementationAndRuntimeHashes() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        manifest.validateRuntimeIdentities(
            address(proxy), address(implementation), address(proxy).codehash, address(implementation).codehash
        );
    }

    function test_rejectsProxyRuntimeHashMismatch() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        vm.expectRevert("proxy runtime fingerprint mismatch");
        manifest.validateRuntimeIdentities(
            address(proxy), address(implementation), bytes32(uint256(1)), address(implementation).codehash
        );
    }

    function test_rejectsProxyImplementationMismatch() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ReleaseTestImplementation other = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        vm.expectRevert("proxy implementation mismatch");
        manifest.validateRuntimeIdentities(
            address(proxy), address(other), address(proxy).codehash, address(other).codehash
        );
    }

    function test_rejectsImplementationRuntimeHashMismatch() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        vm.expectRevert("implementation runtime fingerprint mismatch");
        manifest.validateRuntimeIdentities(
            address(proxy), address(implementation), address(proxy).codehash, bytes32(uint256(1))
        );
    }
}
