// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {IValidationRegistry} from "../src/interfaces/IValidationRegistry.sol";

contract ValidationRegistryTest is Test {
    MockCanonicalIdentityRegistry identity;
    ValidationRegistry validation;

    address admin = makeAddr("admin");
    address agentOwner = makeAddr("agentOwner");
    address validator = makeAddr("validator");
    address stranger = makeAddr("stranger");

    uint256 agentId;
    bytes32 constant REQ_HASH = keccak256("request-1");

    function setUp() public {
        identity = new MockCanonicalIdentityRegistry();

        ValidationRegistry vImpl = new ValidationRegistry();
        ERC1967Proxy vProxy =
            new ERC1967Proxy(address(vImpl), abi.encodeCall(ValidationRegistry.initialize, (address(identity), admin)));
        validation = ValidationRegistry(address(vProxy));

        vm.prank(agentOwner);
        agentId = identity.register();
    }

    function _key(uint256 id, bytes32 requestHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, requestHash));
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

    function test_validationRequestEmptyUriReverts() public {
        vm.prank(agentOwner);
        vm.expectRevert("empty request URI");
        validation.validationRequest(validator, agentId, "", REQ_HASH);
    }

    function test_validationRequestZeroHashReverts() public {
        vm.prank(agentOwner);
        vm.expectRevert("zero request hash");
        validation.validationRequest(validator, agentId, "ipfs://req", bytes32(0));
    }

    function test_computeValidationKey() public view {
        assertEq(validation.computeValidationKey(agentId, REQ_HASH), _key(agentId, REQ_HASH));
    }

    function test_validationRequestDuplicateReverts() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(agentOwner);
        vm.expectRevert("request exists");
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
    }

    function test_sameRequestHashAcrossAgentsUsesDistinctKeys() public {
        address otherOwner = makeAddr("otherOwner");
        vm.prank(otherOwner);
        uint256 otherAgentId = identity.register();

        vm.prank(agentOwner);
        bytes32 firstKey = validation.validationRequest(validator, agentId, "u", REQ_HASH);

        vm.prank(otherOwner);
        bytes32 secondKey = validation.validationRequest(validator, otherAgentId, "u", REQ_HASH);

        assertTrue(firstKey != secondKey);
        assertEq(firstKey, _key(agentId, REQ_HASH));
        assertEq(secondKey, _key(otherAgentId, REQ_HASH));
    }

    function test_validationResponseHappyPath() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);

        vm.expectEmit(true, true, true, true, address(validation));
        emit IValidationRegistry.ValidationResponse(
            validator, agentId, REQ_HASH, 100, "ipfs://resp", keccak256("resp"), "pass"
        );

        vm.prank(validator);
        validation.validationResponse(_key(agentId, REQ_HASH), 100, "ipfs://resp", keccak256("resp"), "pass");

        (
            address validatorAddr,
            uint256 aId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        ) = validation.getValidationStatus(_key(agentId, REQ_HASH));
        assertEq(validatorAddr, validator);
        assertEq(aId, agentId);
        assertEq(response, 100);
        assertEq(responseHash, keccak256("resp"));
        assertEq(keccak256(bytes(tag)), keccak256(bytes("pass")));
        assertGt(lastUpdate, 0);
        assertTrue(validation.hasValidationResponse(_key(agentId, REQ_HASH)));
    }

    function test_zeroResponseIsDistinguishedFromPending() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        bytes32 key = _key(agentId, REQ_HASH);
        assertFalse(validation.hasValidationResponse(key));

        vm.prank(validator);
        validation.validationResponse(key, 0, "", bytes32(0), "fail");

        assertTrue(validation.hasValidationResponse(key));
        address[] memory validators = new address[](0);
        (uint64 count, uint8 average) = validation.getSummary(agentId, validators, "fail");
        assertEq(count, 1);
        assertEq(average, 0);
    }

    function test_validationResponseOnlyByValidator() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(stranger);
        vm.expectRevert("not validator");
        validation.validationResponse(_key(agentId, REQ_HASH), 50, "", bytes32(0), "");
    }

    function test_validationResponseOutOfRangeReverts() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(validator);
        vm.expectRevert("response > 100");
        validation.validationResponse(_key(agentId, REQ_HASH), 101, "", bytes32(0), "");
    }

    function test_validationResponseProgressive() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "ipfs://req", REQ_HASH);
        vm.prank(validator);
        validation.validationResponse(_key(agentId, REQ_HASH), 50, "", bytes32(0), "soft");
        vm.prank(validator);
        validation.validationResponse(_key(agentId, REQ_HASH), 100, "", bytes32(0), "hard");

        (,, uint8 response,, string memory tag,) = validation.getValidationStatus(_key(agentId, REQ_HASH));
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
        assertEq(arr[0], _key(agentId, h1));
        assertEq(arr[1], _key(agentId, h2));
    }

    function test_getValidatorRequests() public {
        vm.prank(agentOwner);
        validation.validationRequest(validator, agentId, "u1", REQ_HASH);
        bytes32[] memory arr = validation.getValidatorRequests(validator);
        assertEq(arr.length, 1);
        assertEq(arr[0], _key(agentId, REQ_HASH));
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
        assertEq(page[0], _key(agentId, hashes[1]));
        assertEq(page[1], _key(agentId, hashes[2]));

        bytes32[] memory tail = validation.getAgentValidationsPaginated(agentId, 3, 99);
        assertEq(tail.length, 1);
        assertEq(tail[0], _key(agentId, hashes[3]));

        bytes32[] memory past = validation.getAgentValidationsPaginated(agentId, 4, 1);
        assertEq(past.length, 0);

        // Sentinel-size limit with a nonzero offset clamps to the tail
        // instead of overflowing offset+limit.
        bytes32[] memory sentinel = validation.getAgentValidationsPaginated(agentId, 1, type(uint256).max);
        assertEq(sentinel.length, 3);
        assertEq(sentinel[2], _key(agentId, hashes[3]));
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
        assertEq(page[0], _key(agentId, hashes[0]));
        assertEq(page[1], _key(agentId, hashes[1]));
    }

    function test_getSummaryFiltersCompletedResponses() public {
        bytes32 h1 = keccak256("summary-1");
        bytes32 h2 = keccak256("summary-2");
        vm.startPrank(agentOwner);
        validation.validationRequest(validator, agentId, "u1", h1);
        validation.validationRequest(validator, agentId, "u2", h2);
        vm.stopPrank();

        vm.prank(validator);
        validation.validationResponse(_key(agentId, h1), 80, "", bytes32(0), "security");

        address[] memory validators = new address[](1);
        validators[0] = validator;
        (uint64 count, uint8 average) = validation.getSummary(agentId, validators, "security");
        assertEq(count, 1);
        assertEq(average, 80);
    }

    function test_getSummaryPaginatedReturnsPartialCountAndSum() public {
        bytes32[] memory hashes = new bytes32[](4);
        vm.startPrank(agentOwner);
        for (uint256 i = 0; i < hashes.length; i++) {
            hashes[i] = keccak256(abi.encode("summary-page", i));
            validation.validationRequest(validator, agentId, "u", hashes[i]);
        }
        vm.stopPrank();

        vm.startPrank(validator);
        validation.validationResponse(_key(agentId, hashes[0]), 10, "", bytes32(0), "score");
        validation.validationResponse(_key(agentId, hashes[1]), 20, "", bytes32(0), "other");
        validation.validationResponse(_key(agentId, hashes[2]), 30, "", bytes32(0), "score");
        vm.stopPrank();

        address[] memory validators = new address[](0);
        (uint64 firstCount, uint256 firstTotal, uint256 firstNext) =
            validation.getSummaryPaginated(agentId, validators, "score", 0, 2);
        assertEq(firstCount, 1);
        assertEq(firstTotal, 10);
        assertEq(firstNext, 2);

        (uint64 secondCount, uint256 secondTotal, uint256 secondNext) =
            validation.getSummaryPaginated(agentId, validators, "score", firstNext, 2);
        assertEq(secondCount, 1);
        assertEq(secondTotal, 30);
        assertEq(secondNext, 4);

        (uint64 pastCount, uint256 pastTotal, uint256 pastNext) =
            validation.getSummaryPaginated(agentId, validators, "score", 99, 2);
        assertEq(pastCount, 0);
        assertEq(pastTotal, 0);
        assertEq(pastNext, 4);
    }
}
