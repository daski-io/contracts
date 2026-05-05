// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

contract ReputationRegistryTest is Test {
    IdentityRegistry identity;
    ReputationRegistry reputation;

    address admin = makeAddr("admin");
    address agentOwner = makeAddr("agentOwner");
    address client1 = makeAddr("client1");
    address client2 = makeAddr("client2");

    uint256 agentId;

    function setUp() public {
        IdentityRegistry idImpl = new IdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(address(idImpl), abi.encodeCall(IdentityRegistry.initialize, (admin)));
        identity = IdentityRegistry(address(idProxy));

        ReputationRegistry repImpl = new ReputationRegistry();
        ERC1967Proxy repProxy = new ERC1967Proxy(
            address(repImpl), abi.encodeCall(ReputationRegistry.initialize, (address(identity), admin))
        );
        reputation = ReputationRegistry(address(repProxy));

        vm.prank(agentOwner);
        agentId = identity.register("ipfs://agent");
    }

    function test_getIdentityRegistry() public view {
        assertEq(reputation.getIdentityRegistry(), address(identity));
    }

    function test_giveFeedbackHappyPath() public {
        vm.prank(client1);
        reputation.giveFeedback(agentId, 87, 0, "starred", "", "", "", bytes32(0));

        (int128 value, uint8 decimals, string memory tag1, string memory tag2, bool revoked) =
            reputation.readFeedback(agentId, client1, 1);
        assertEq(value, 87);
        assertEq(decimals, 0);
        assertEq(keccak256(bytes(tag1)), keccak256(bytes("starred")));
        assertEq(keccak256(bytes(tag2)), keccak256(bytes("")));
        assertFalse(revoked);

        assertEq(reputation.getLastIndex(agentId, client1), 1);
        address[] memory clients = reputation.getClients(agentId);
        assertEq(clients.length, 1);
        assertEq(clients[0], client1);
    }

    function test_giveFeedbackByOwnerReverts() public {
        vm.prank(agentOwner);
        vm.expectRevert("owner cannot self-review");
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));
    }

    function test_giveFeedbackByOperatorReverts() public {
        vm.prank(agentOwner);
        identity.setApprovalForAll(client1, true);

        vm.prank(client1);
        vm.expectRevert("operator cannot review");
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));
    }

    // M-2: per-token approval (approve, not setApprovalForAll) must also be
    // excluded. Without this, an owner could approve an alt wallet for the
    // tokenId and have the alt wallet submit self-praise.
    function test_giveFeedbackByApprovedSpenderReverts() public {
        vm.prank(agentOwner);
        identity.approve(client1, agentId);

        vm.prank(client1);
        vm.expectRevert("approved spender cannot review");
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));
    }

    function test_valueDecimalsTooHighReverts() public {
        vm.prank(client1);
        vm.expectRevert("valueDecimals > 18");
        reputation.giveFeedback(agentId, 1, 19, "", "", "", "", bytes32(0));
    }

    function test_revokeFeedback() public {
        vm.prank(client1);
        reputation.giveFeedback(agentId, 50, 0, "", "", "", "", bytes32(0));

        vm.prank(client1);
        reputation.revokeFeedback(agentId, 1);

        (,,,, bool revoked) = reputation.readFeedback(agentId, client1, 1);
        assertTrue(revoked);
    }

    function test_revokeNonexistentReverts() public {
        vm.prank(client1);
        vm.expectRevert("no such feedback");
        reputation.revokeFeedback(agentId, 1);
    }

    function test_multipleFeedbacksIndexMonotone() public {
        vm.startPrank(client1);
        reputation.giveFeedback(agentId, 10, 0, "", "", "", "", bytes32(0));
        reputation.giveFeedback(agentId, 20, 0, "", "", "", "", bytes32(0));
        reputation.giveFeedback(agentId, 30, 0, "", "", "", "", bytes32(0));
        vm.stopPrank();
        assertEq(reputation.getLastIndex(agentId, client1), 3);
    }

    function test_multipleClientsAccumulate() public {
        vm.prank(client1);
        reputation.giveFeedback(agentId, 10, 0, "", "", "", "", bytes32(0));
        vm.prank(client2);
        reputation.giveFeedback(agentId, 20, 0, "", "", "", "", bytes32(0));

        address[] memory clients = reputation.getClients(agentId);
        assertEq(clients.length, 2);
    }

    function test_appendResponse() public {
        vm.prank(client1);
        reputation.giveFeedback(agentId, 50, 0, "", "", "", "", bytes32(0));

        vm.prank(agentOwner);
        reputation.appendResponse(agentId, client1, 1, "ipfs://response", keccak256("response"));
    }

    function test_feedbackForNonexistentAgentReverts() public {
        vm.prank(client1);
        vm.expectRevert(); // ERC721NonexistentToken
        reputation.giveFeedback(999, 50, 0, "", "", "", "", bytes32(0));
    }

    function test_newFeedbackEvent() public {
        vm.expectEmit(true, true, false, true, address(reputation));
        emit IReputationRegistry.NewFeedback(
            agentId, client1, 1, 42, 2, "starred", "starred", "quality", "https://ep", "ipfs://cid", bytes32(0)
        );
        vm.prank(client1);
        reputation.giveFeedback(agentId, 42, 2, "starred", "quality", "https://ep", "ipfs://cid", bytes32(0));
    }
}
