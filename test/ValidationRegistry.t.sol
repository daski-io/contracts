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

    /// @dev Independent re-derivation of the namespaced storage key, mirroring
    ///      ValidationRegistry._validationKey (agentId-scoped).
    function _key(bytes32 reqHash) internal view returns (bytes32) {
        return keccak256(abi.encode(agentId, reqHash));
    }

    function test_validationRequestEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(validation));
        emit IValidationRegistry.ValidationRequest(validator, agentId, "ipfs://req", REQ_HASH);

        vm.prank(agentOwner);
        bytes32 key = validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        assertEq(key, _key(REQ_HASH), "returned key matches derivation");
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

    // L-2: the same requestHash registered for two different agents must NOT
    // collide. The key is namespaced by agentId and validationRequest is
    // auth-gated on agentId, so a front-runner cannot squat another agent's slot.
    function test_sameRequestHashAcrossAgents_noCollision() public {
        address otherOwner = makeAddr("otherOwner");
        vm.prank(otherOwner);
        uint256 otherAgentId = identity.register();

        vm.prank(agentOwner);
        bytes32 k1 = validation.validationRequest(validator, agentId, "u", REQ_HASH);

        // Same REQ_HASH, different agent — must not revert.
        vm.prank(otherOwner);
        bytes32 k2 = validation.validationRequest(validator, otherAgentId, "u", REQ_HASH);

        assertTrue(k1 != k2, "keys namespaced by agentId");
        assertEq(k1, keccak256(abi.encode(agentId, REQ_HASH)));
        assertEq(k2, keccak256(abi.encode(otherAgentId, REQ_HASH)));

        (, uint256 a1,,,,,) = validation.getValidationStatus(k1);
        (, uint256 a2,,,,,) = validation.getValidationStatus(k2);
        assertEq(a1, agentId);
        assertEq(a2, otherAgentId);
    }

    function test_validationResponseHappyPath() public {
        vm.prank(agentOwner);
        bytes32 key = validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);

        vm.expectEmit(true, true, true, true, address(validation));
        emit IValidationRegistry.ValidationResponse(
            validator, agentId, REQ_HASH, 100, "ipfs://resp", keccak256("resp"), "pass"
        );

        vm.prank(validator);
        validation.validationResponse(key, 100, "ipfs://resp", keccak256("resp"), "pass");

        (
            address validatorAddr,
            uint256 aId,
            bytes32 reqHash,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        ) = validation.getValidationStatus(key);
        assertEq(validatorAddr, validator);
        assertEq(aId, agentId);
        assertEq(reqHash, REQ_HASH);
        assertEq(response, 100);
        assertEq(responseHash, keccak256("resp"));
        assertEq(keccak256(bytes(tag)), keccak256(bytes("pass")));
        assertGt(lastUpdate, 0);
    }

    function test_validationResponseOnlyByValidator() public {
        vm.prank(agentOwner);
        bytes32 key = validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(stranger);
        vm.expectRevert("not validator");
        validation.validationResponse(key, 50, "", bytes32(0), "");
    }

    function test_validationResponseOutOfRangeReverts() public {
        vm.prank(agentOwner);
        bytes32 key = validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(validator);
        vm.expectRevert("response > 100");
        validation.validationResponse(key, 101, "", bytes32(0), "");
    }

    function test_validationResponseProgressive() public {
        vm.prank(agentOwner);
        bytes32 key = validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(validator);
        validation.validationResponse(key, 50, "", bytes32(0), "soft");
        vm.prank(validator);
        validation.validationResponse(key, 100, "", bytes32(0), "hard");

        (,,, uint8 response,, string memory tag,) = validation.getValidationStatus(key);
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
        assertEq(arr[0], _key(h1));
        assertEq(arr[1], _key(h2));
    }

    function test_getValidatorRequests() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "u1", REQ_HASH);
        bytes32[] memory arr = validation.getValidatorRequests(validator);
        assertEq(arr.length, 1);
        assertEq(arr[0], _key(REQ_HASH));
    }

    // L-2: paginated views for agent and validator request lists.
    function test_paginatedAgentValidations() public {
        bytes32[] memory hashes = new bytes32[](4);
        vm.startPrank(agentOwner);
        for (uint256 i = 0; i < 4; i++) {
            hashes[i] = keccak256(abi.encode("h", i));
            validation.validationRequest(validator, agentId, "u", hashes[i]);
        }
        vm.stopPrank();

        assertEq(validation.getAgentValidationCount(agentId), 4);

        bytes32[] memory page = validation.getAgentValidationsPaginated(agentId, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], _key(hashes[1]));
        assertEq(page[1], _key(hashes[2]));

        bytes32[] memory tail = validation.getAgentValidationsPaginated(agentId, 3, 99);
        assertEq(tail.length, 1);
        assertEq(tail[0], _key(hashes[3]));

        bytes32[] memory past = validation.getAgentValidationsPaginated(agentId, 4, 1);
        assertEq(past.length, 0);
    }

    function test_paginatedValidatorRequests() public {
        bytes32[] memory hashes = new bytes32[](3);
        vm.startPrank(agentOwner);
        for (uint256 i = 0; i < 3; i++) {
            hashes[i] = keccak256(abi.encode("vh", i));
            validation.validationRequest(validator, agentId, "u", hashes[i]);
        }
        vm.stopPrank();

        assertEq(validation.getValidatorRequestCount(validator), 3);

        bytes32[] memory page = validation.getValidatorRequestsPaginated(validator, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], _key(hashes[0]));
        assertEq(page[1], _key(hashes[1]));
    }
}
