// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployReputationStorage} from "../script/DeployReputationStorage.s.sol";
import {ReputationEASIdentity} from "../script/ReputationEASIdentity.sol";
import {IEAS} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {
    DeployReputationStorageHarness,
    ReputationEASImplementationStub,
    ReputationProxyRuntimeStub,
    ReputationSchemaImplementationStub
} from "./helpers/ReputationDeploymentHarness.sol";

contract ReputationEASIdentityTest is Test {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DeployReputationStorageHarness private script;

    function setUp() public {
        script = new DeployReputationStorageHarness();
    }

    function test_reviewedProductionRuntimeIdentitiesArePinnedPerChain() public {
        DeployReputationStorage production = new DeployReputationStorage();
        (bytes32 baseProxy,, bytes32 baseEAS,, bytes32 baseSchema) = production.reviewedEASDeployment(BASE_CHAIN_ID);
        assertEq(baseProxy, 0x1f958654ab06a152993e7a0ae7b6dbb0d4b19265cc9337b8789fe1353bd9dc35);
        assertEq(baseEAS, 0x16b293cd7ed66fa1e03076e5847c59b146a83c187d991c42fe6056b3c1cc0513);
        assertEq(baseSchema, 0x020abfe7296543ec2d825b97a9c3fe26d7beea1fbf80de58e0da20e2a6825753);

        (bytes32 sepoliaProxy,, bytes32 sepoliaEAS,, bytes32 sepoliaSchema) =
            production.reviewedEASDeployment(BASE_SEPOLIA_CHAIN_ID);
        assertEq(sepoliaProxy, 0xfa8c9db6c6cab7108dea276f4cd09d575674eb0852c0fa3187e59e98ef977998);
        assertEq(sepoliaEAS, 0x703f246f804f8d4b315fd7b5fc504671f726230373571e02b69794d0f2614fd7);
        assertEq(sepoliaSchema, 0x4f01862031e523fc22a2bbe86c670a2f57f0da57ce1f582b0776042290377672);
    }

    function test_supportedChainRequiresReviewedProxyAndImplementations() public {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        (address easAddress, address registryAddress) = _installReviewedDeployment();
        assertEq(script.validateEAS(easAddress, false), registryAddress);

        bytes32 expectedHash = keccak256(type(ReputationEASImplementationStub).runtimeCode);
        bytes memory wrongRuntime = type(ReputationSchemaImplementationStub).runtimeCode;
        vm.etch(script.easImplementation(), wrongRuntime);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationEASIdentity.UnexpectedRuntimeCodeHash.selector,
                script.easImplementation(),
                expectedHash,
                keccak256(wrongRuntime)
            )
        );
        script.validateEAS(easAddress, false);
    }

    function test_supportedChainRejectsWrongAddressRegistryAndImplementation() public {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        (address easAddress, address registryAddress) = _installReviewedDeployment();
        MockEAS wrongEAS = new MockEAS();
        vm.expectRevert(
            abi.encodeWithSelector(ReputationEASIdentity.UnexpectedEAS.selector, easAddress, address(wrongEAS))
        );
        script.validateEAS(address(wrongEAS), true);

        vm.mockCall(easAddress, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(address(wrongEAS)));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationEASIdentity.UnexpectedSchemaRegistry.selector, registryAddress, address(wrongEAS)
            )
        );
        script.validateEAS(easAddress, false);

        vm.mockCall(easAddress, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(registryAddress));
        address wrongImplementation = makeAddr("wrong-eas-implementation");
        vm.store(easAddress, EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(wrongImplementation))));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationEASIdentity.UnexpectedImplementation.selector,
                easAddress,
                script.easImplementation(),
                wrongImplementation
            )
        );
        script.validateEAS(easAddress, false);
    }

    function test_unsupportedChainRequiresExplicitOverride() public {
        vm.chainId(31337);
        MockEAS localEAS = new MockEAS();
        vm.expectRevert(abi.encodeWithSelector(ReputationEASIdentity.UnsupportedEASChain.selector, block.chainid));
        script.validateEAS(address(localEAS), false);
        assertEq(script.validateEAS(address(localEAS), true), address(localEAS));
    }

    function _installReviewedDeployment() private returns (address easAddress, address registryAddress) {
        easAddress = script.canonicalEAS(block.chainid);
        registryAddress = script.canonicalSchemaRegistry(block.chainid);
        vm.etch(easAddress, type(ReputationProxyRuntimeStub).runtimeCode);
        vm.etch(registryAddress, type(ReputationProxyRuntimeStub).runtimeCode);
        vm.etch(script.easImplementation(), type(ReputationEASImplementationStub).runtimeCode);
        vm.etch(script.schemaImplementation(), type(ReputationSchemaImplementationStub).runtimeCode);
        vm.store(easAddress, EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(script.easImplementation()))));
        vm.store(registryAddress, EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(script.schemaImplementation()))));
        vm.mockCall(easAddress, abi.encodeCall(IEAS.getSchemaRegistry, ()), abi.encode(registryAddress));
    }
}
