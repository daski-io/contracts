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

    // M-3 fix: only the agent (owner / approved operator / approved spender)
    // may append responses. Without this gate, anyone could spam arbitrary
    // responses, polluting the off-chain index.
    function test_appendResponseByStrangerReverts() public {
        vm.prank(client1);
        reputation.giveFeedback(agentId, 50, 0, "", "", "", "", bytes32(0));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("not owner or operator");
        reputation.appendResponse(agentId, client1, 1, "ipfs://spam", keccak256("spam"));
    }

    function test_appendResponseByOperatorOk() public {
        vm.prank(client1);
        reputation.giveFeedback(agentId, 50, 0, "", "", "", "", bytes32(0));

        address operator = makeAddr("operator");
        vm.prank(agentOwner);
        identity.setApprovalForAll(operator, true);

        vm.prank(operator);
        reputation.appendResponse(agentId, client1, 1, "ipfs://by-op", keccak256("by-op"));
    }

    function test_feedbackForNonexistentAgentReverts() public {
        vm.prank(client1);
        vm.expectRevert(); // ERC721NonexistentToken
        reputation.giveFeedback(999, 50, 0, "", "", "", "", bytes32(0));
    }

    // M-1 fix: the agent's payment wallet (per ERC-8004) may differ from
    // the NFT owner. It must not be allowed to self-review.
    function test_giveFeedbackByAgentWalletReverts() public {
        // Bind a fresh wallet as the agent's payment wallet.
        uint256 walletKey = 0xCAFE;
        address walletAddr = vm.addr(walletKey);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 typehash = identity.SET_AGENT_WALLET_TYPEHASH();
        uint256 nonce = identity.walletRotationNonce(walletAddr);
        bytes32 structHash = keccak256(abi.encode(typehash, agentId, walletAddr, nonce, deadline));
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Daski IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(identity)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(agentOwner);
        identity.setAgentWallet(agentId, walletAddr, deadline, sig);
        assertEq(identity.getAgentWallet(agentId), walletAddr);

        // walletAddr is neither owner, operator, nor approved spender — but
        // it IS the agent's payment wallet, so self-review must be blocked.
        vm.prank(walletAddr);
        vm.expectRevert("agentWallet cannot self-review");
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));
    }

    // L-2: paginated client list views.
    function test_clientsPaginationAndCount() public {
        // Seed 5 distinct reviewers.
        address[5] memory reviewers = [makeAddr("rA"), makeAddr("rB"), makeAddr("rC"), makeAddr("rD"), makeAddr("rE")];
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(reviewers[i]);
            reputation.giveFeedback(agentId, 1, 0, "", "", "", "", bytes32(0));
        }

        assertEq(reputation.getClientCount(agentId), 5);

        address[] memory page1 = reputation.getClientsPaginated(agentId, 0, 2);
        assertEq(page1.length, 2);
        assertEq(page1[0], reviewers[0]);
        assertEq(page1[1], reviewers[1]);

        address[] memory page2 = reputation.getClientsPaginated(agentId, 2, 2);
        assertEq(page2.length, 2);
        assertEq(page2[0], reviewers[2]);
        assertEq(page2[1], reviewers[3]);

        // Limit larger than remaining — clamp to count.
        address[] memory tail = reputation.getClientsPaginated(agentId, 4, 100);
        assertEq(tail.length, 1);
        assertEq(tail[0], reviewers[4]);

        // Offset past end → empty.
        address[] memory past = reputation.getClientsPaginated(agentId, 5, 10);
        assertEq(past.length, 0);
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
