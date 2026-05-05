// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {IValidationRegistry} from "../src/interfaces/IValidationRegistry.sol";

contract ValidationRegistryTest is Test {
    IdentityRegistry identity;
    ValidationRegistry validation;

    address admin = makeAddr("admin");
    address agentOwner = makeAddr("agentOwner");
    address validator = makeAddr("validator");
    address stranger = makeAddr("stranger");

    uint256 agentId;
    bytes32 constant REQ_HASH = keccak256("request-1");

    function setUp() public {
        IdentityRegistry idImpl = new IdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(address(idImpl), abi.encodeCall(IdentityRegistry.initialize, (admin)));
        identity = IdentityRegistry(address(idProxy));

        ValidationRegistry vImpl = new ValidationRegistry();
        ERC1967Proxy vProxy =
            new ERC1967Proxy(address(vImpl), abi.encodeCall(ValidationRegistry.initialize, (address(identity), admin)));
        validation = ValidationRegistry(address(vProxy));

        vm.prank(agentOwner);
        agentId = identity.register();
    }

    function test_validationRequestEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(validation));
        emit IValidationRegistry.ValidationRequest(validator, agentId, "ipfs://req", REQ_HASH);

        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
    }

    function test_validationRequestByStrangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert("not owner or operator");
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
    }

    function test_validationRequestZeroValidatorReverts() public {
        vm.prank(agentOwner);
        vm.expectRevert("zero validator");
        validation.validationRequest(address(0), agentId, "ipfs://req", REQ_HASH);
    }

    function test_validationRequestDuplicateReverts() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(agentOwner);
        vm.expectRevert("request exists");
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
    }

    function test_validationResponseHappyPath() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);

        vm.expectEmit(true, true, true, true, address(validation));
        emit IValidationRegistry.ValidationResponse(
            validator, agentId, REQ_HASH, 100, "ipfs://resp", keccak256("resp"), "pass"
        );

        vm.prank(validator);
        validation.validationResponse(REQ_HASH, 100, "ipfs://resp", keccak256("resp"), "pass");

        (
            address validatorAddr,
            uint256 aId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        ) = validation.getValidationStatus(REQ_HASH);
        assertEq(validatorAddr, validator);
        assertEq(aId, agentId);
        assertEq(response, 100);
        assertEq(responseHash, keccak256("resp"));
        assertEq(keccak256(bytes(tag)), keccak256(bytes("pass")));
        assertGt(lastUpdate, 0);
    }

    function test_validationResponseOnlyByValidator() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(stranger);
        vm.expectRevert("not validator");
        validation.validationResponse(REQ_HASH, 50, "", bytes32(0), "");
    }

    function test_validationResponseOutOfRangeReverts() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(validator);
        vm.expectRevert("response > 100");
        validation.validationResponse(REQ_HASH, 101, "", bytes32(0), "");
    }

    function test_validationResponseProgressive() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(validator);
        validation.validationResponse(REQ_HASH, 50, "", bytes32(0), "soft");
        vm.prank(validator);
        validation.validationResponse(REQ_HASH, 100, "", bytes32(0), "hard");

        (,, uint8 response,, string memory tag,) = validation.getValidationStatus(REQ_HASH);
        assertEq(response, 100);
        assertEq(keccak256(bytes(tag)), keccak256(bytes("hard")));
    }

    function test_getAgentValidations() public {
        bytes32 h1 = keccak256("r1");
        bytes32 h2 = keccak256("r2");
        vm.startPrank(agentOwner);
        validation.validationRequest(validator, agentId, "u1", h1);
        validation.validationRequest(validator, agentId, "u2", h2);
        vm.stopPrank();

        bytes32[] memory arr = validation.getAgentValidations(agentId);
        assertEq(arr.length, 2);
        assertEq(arr[0], h1);
        assertEq(arr[1], h2);
    }

    function test_getValidatorRequests() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "u1", REQ_HASH);
        bytes32[] memory arr = validation.getValidatorRequests(validator);
        assertEq(arr.length, 1);
        assertEq(arr[0], REQ_HASH);
    }
}
