// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationEASIdentity} from "../script/ReputationEASIdentity.sol";
import {IEAS} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {DeployReputationStorageHarness} from "./helpers/ReputationDeploymentHarness.sol";

contract EASCodeStubOne {
    fallback() external {}
}

contract EASCodeStubTwo {
    fallback() external {}
}

contract ReputationEASIdentityTest is Test {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;

    DeployReputationStorageHarness private script;

    function setUp() public {
        script = new DeployReputationStorageHarness();
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
    }

    function test_canonicalAddressesAreFixedOnSupportedChains() public view {
        assertEq(script.canonicalEAS(BASE_CHAIN_ID), 0x4200000000000000000000000000000000000021);
        assertEq(script.canonicalEAS(BASE_SEPOLIA_CHAIN_ID), 0x4200000000000000000000000000000000000021);
        assertEq(script.canonicalSchemaRegistry(BASE_CHAIN_ID), 0x4200000000000000000000000000000000000020);
        assertEq(script.canonicalSchemaRegistry(BASE_SEPOLIA_CHAIN_ID), 0x4200000000000000000000000000000000000020);
    }

    function test_acceptsCanonicalContractsWithoutRuntimePins() public {
        (address easAddress, address registryAddress) = _installCanonicalContracts();
        assertEq(script.validateEAS(easAddress), registryAddress);

        vm.etch(easAddress, type(EASCodeStubTwo).runtimeCode);
        vm.etch(registryAddress, type(EASCodeStubTwo).runtimeCode);
        assertEq(script.validateEAS(easAddress), registryAddress);
    }

    function test_rejectsWrongEASOrSchemaRegistryAddress() public {
        (address easAddress, address registryAddress) = _installCanonicalContracts();
        MockEAS wrong = new MockEAS();
        vm.expectRevert(
            abi.encodeWithSelector(ReputationEASIdentity.UnexpectedEAS.selector, easAddress, address(wrong))
        );
        script.validateEAS(address(wrong));

        vm.mockCall(easAddress, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(address(wrong)));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationEASIdentity.UnexpectedSchemaRegistry.selector, registryAddress, address(wrong)
            )
        );
        script.validateEAS(easAddress);
    }

    function test_requiresCodeAtBothCanonicalAddresses() public {
        address easAddress = script.canonicalEAS(block.chainid);
        address registryAddress = script.canonicalSchemaRegistry(block.chainid);
        vm.etch(easAddress, bytes(""));
        vm.etch(registryAddress, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(ReputationEASIdentity.ExternalDependencyHasNoCode.selector, easAddress));
        script.validateEAS(easAddress);

        vm.etch(easAddress, type(EASCodeStubOne).runtimeCode);
        vm.mockCall(easAddress, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(registryAddress));
        vm.expectRevert(
            abi.encodeWithSelector(ReputationEASIdentity.ExternalDependencyHasNoCode.selector, registryAddress)
        );
        script.validateEAS(easAddress);
    }

    function test_rejectsUnsupportedChain() public {
        vm.chainId(31337);
        MockEAS localEAS = new MockEAS();
        vm.expectRevert(abi.encodeWithSelector(ReputationEASIdentity.UnsupportedEASChain.selector, block.chainid));
        script.validateEAS(address(localEAS));
    }

    function _installCanonicalContracts() private returns (address easAddress, address registryAddress) {
        easAddress = script.canonicalEAS(block.chainid);
        registryAddress = script.canonicalSchemaRegistry(block.chainid);
        vm.etch(easAddress, type(EASCodeStubOne).runtimeCode);
        vm.etch(registryAddress, type(EASCodeStubOne).runtimeCode);
        vm.mockCall(easAddress, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(registryAddress));
    }
}
