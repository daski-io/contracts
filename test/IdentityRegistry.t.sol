// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

contract IdentityRegistryTest is Test {
    IdentityRegistry identity;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant ALICE_KEY = 0xA11CE;
    address aliceSigner;

    function setUp() public {
        IdentityRegistry impl = new IdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(IdentityRegistry.initialize, (admin)));
        identity = IdentityRegistry(address(proxy));

        aliceSigner = vm.addr(ALICE_KEY);
    }

    // --- Registration ----------------------------------------------------

    function test_registerNoArgs() public {
        vm.prank(alice);
        uint256 agentId = identity.register();
        assertEq(agentId, 1);
        assertEq(identity.ownerOf(agentId), alice);
        assertEq(bytes(identity.tokenURI(agentId)).length, 0);
    }

    function test_registerWithUri() public {
        string memory uri = "https://alice.example/agent.json";
        vm.prank(alice);
        uint256 agentId = identity.register(uri);
        assertEq(agentId, 1);
        assertEq(identity.tokenURI(agentId), uri);
    }

    function test_registerWithMetadata() public {
        IIdentityRegistry.MetadataEntry[] memory md = new IIdentityRegistry.MetadataEntry[](1);
        md[0] = IIdentityRegistry.MetadataEntry({metadataKey: "category", metadataValue: bytes("domain-registration")});

        vm.prank(alice);
        uint256 agentId = identity.register("ipfs://cid", md);

        bytes memory stored = identity.getMetadata(agentId, "category");
        assertEq(keccak256(stored), keccak256(bytes("domain-registration")));
    }

    function test_registerRejectsReservedAgentWalletKey() public {
        IIdentityRegistry.MetadataEntry[] memory md = new IIdentityRegistry.MetadataEntry[](1);
        md[0] = IIdentityRegistry.MetadataEntry({metadataKey: "agentWallet", metadataValue: abi.encodePacked(bob)});

        vm.prank(alice);
        vm.expectRevert("agentWallet is reserved");
        identity.register("uri", md);
    }

    function test_registerEmitsRegistered() public {
        vm.expectEmit(true, false, true, true, address(identity));
        emit IIdentityRegistry.Registered(1, "ipfs://x", alice);
        vm.prank(alice);
        identity.register("ipfs://x");
    }

    function test_tokenIdsIncrementAcrossOwners() public {
        vm.prank(alice);
        uint256 a = identity.register();
        vm.prank(bob);
        uint256 b = identity.register();
        assertEq(a, 1);
        assertEq(b, 2);
    }

    // --- Agent URI -------------------------------------------------------

    function test_setAgentURIByOwner() public {
        vm.prank(alice);
        uint256 agentId = identity.register("old");

        vm.expectEmit(true, false, true, true, address(identity));
        emit IIdentityRegistry.URIUpdated(agentId, "new", alice);
        vm.prank(alice);
        identity.setAgentURI(agentId, "new");
        assertEq(identity.tokenURI(agentId), "new");
    }

    function test_setAgentURIByStrangerReverts() public {
        vm.prank(alice);
        uint256 agentId = identity.register("old");
        vm.prank(bob);
        vm.expectRevert("not owner or operator");
        identity.setAgentURI(agentId, "new");
    }

    // --- Metadata --------------------------------------------------------

    function test_setGenericMetadata() public {
        vm.prank(alice);
        uint256 agentId = identity.register();
        vm.prank(alice);
        identity.setMetadata(agentId, "key1", bytes("value1"));
        assertEq(keccak256(identity.getMetadata(agentId, "key1")), keccak256(bytes("value1")));
    }

    function test_setMetadataRejectsReservedKey() public {
        vm.prank(alice);
        uint256 agentId = identity.register();
        vm.prank(alice);
        vm.expectRevert("agentWallet is reserved");
        identity.setMetadata(agentId, "agentWallet", abi.encodePacked(bob));
    }

    // --- agentWallet (default = owner; rotation via EIP-712) -------------

    function test_agentWalletDefaultsToOwner() public {
        vm.prank(aliceSigner);
        uint256 agentId = identity.register();
        assertEq(identity.getAgentWallet(agentId), aliceSigner);
        assertEq(identity.agentOfWallet(aliceSigner), agentId);
    }

    function test_setAgentWalletWithValidSignature() public {
        vm.prank(alice);
        uint256 agentId = identity.register();

        address newWallet = vm.addr(0xB0B);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetAgentWallet(0xB0B, agentId, newWallet, deadline);

        vm.prank(alice);
        identity.setAgentWallet(agentId, newWallet, deadline, sig);

        assertEq(identity.getAgentWallet(agentId), newWallet);
        assertEq(identity.agentOfWallet(newWallet), agentId);
        assertEq(identity.agentOfWallet(alice), 0, "old owner wallet cleared");
    }

    function test_setAgentWalletBadSignatureReverts() public {
        vm.prank(alice);
        uint256 agentId = identity.register();
        address newWallet = vm.addr(0xB0B);
        uint256 deadline = block.timestamp + 1 hours;
        // Sign with the WRONG key (charlie) for newWallet = bob's address.
        bytes memory sig = _signSetAgentWallet(0xCAFE, agentId, newWallet, deadline);

        vm.prank(alice);
        vm.expectRevert("invalid wallet signature");
        identity.setAgentWallet(agentId, newWallet, deadline, sig);
    }

    function test_setAgentWalletExpiredReverts() public {
        vm.prank(alice);
        uint256 agentId = identity.register();
        address newWallet = vm.addr(0xB0B);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetAgentWallet(0xB0B, agentId, newWallet, deadline);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vm.expectRevert("signature expired");
        identity.setAgentWallet(agentId, newWallet, deadline, sig);
    }

    function test_setAgentWalletDuplicateMappingReverts() public {
        // Alice registers, wallet defaults to alice.
        vm.prank(alice);
        uint256 aliceId = identity.register();

        // Bob registers.
        vm.prank(bob);
        uint256 bobId = identity.register();

        // Bob tries to set his wallet to alice — should revert because
        // alice's wallet is already mapped to aliceId.
        uint256 deadline = block.timestamp + 1 hours;
        // Sign with any key for alice — the wallet-already-mapped check
        // fires before signature validation.
        bytes memory sig = _signSetAgentWallet(ALICE_KEY, bobId, alice, deadline);
        vm.prank(bob);
        vm.expectRevert("wallet already mapped");
        identity.setAgentWallet(bobId, alice, deadline, sig);

        aliceId; // silence unused-var warning
    }

    function test_unsetAgentWallet() public {
        vm.prank(alice);
        uint256 agentId = identity.register();
        vm.prank(alice);
        identity.unsetAgentWallet(agentId);
        assertEq(identity.getAgentWallet(agentId), address(0));
        assertEq(identity.agentOfWallet(alice), 0);
    }

    function test_transferClearsAgentWallet() public {
        vm.prank(alice);
        uint256 agentId = identity.register();

        vm.prank(alice);
        identity.transferFrom(alice, bob, agentId);

        assertEq(identity.ownerOf(agentId), bob);
        assertEq(identity.getAgentWallet(agentId), address(0), "wallet cleared on transfer");
        assertEq(identity.agentOfWallet(alice), 0);
        assertEq(identity.agentOfWallet(bob), 0);
    }

    // --- Gasless registration (registerBySig) ----------------------------

    function test_registerBySig_happy() public {
        string memory uri = "ipfs://gasless";
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = identity.registrationNonce(aliceSigner);
        assertEq(nonce, 0, "nonce starts at 0");

        bytes memory sig = _signRegisterAgent(ALICE_KEY, uri, aliceSigner, nonce, deadline);

        // Anyone (here: bob, simulating the gateway facilitator) submits.
        vm.prank(bob);
        uint256 agentId = identity.registerBySig(uri, aliceSigner, deadline, sig);

        assertEq(agentId, 1);
        assertEq(identity.ownerOf(agentId), aliceSigner, "NFT minted to signer, not relayer");
        assertEq(identity.tokenURI(agentId), uri);
        assertEq(identity.agentOfWallet(aliceSigner), agentId);
        assertEq(identity.registrationNonce(aliceSigner), 1, "nonce incremented");
    }

    function test_registerBySig_expiredDeadlineReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRegisterAgent(ALICE_KEY, "uri", aliceSigner, 0, deadline);

        vm.warp(deadline + 1);
        vm.prank(bob);
        vm.expectRevert("signature expired");
        identity.registerBySig("uri", aliceSigner, deadline, sig);
    }

    function test_registerBySig_zeroWalletReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        // Signature contents don't matter — zero-wallet check fires first.
        bytes memory sig = _signRegisterAgent(ALICE_KEY, "uri", address(0), 0, deadline);

        vm.prank(bob);
        vm.expectRevert("zero wallet");
        identity.registerBySig("uri", address(0), deadline, sig);
    }

    function test_registerBySig_alreadyRegisteredReverts() public {
        // Pre-register aliceSigner with a normal call.
        vm.prank(aliceSigner);
        identity.register();

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRegisterAgent(ALICE_KEY, "uri", aliceSigner, 0, deadline);

        vm.prank(bob);
        vm.expectRevert("wallet already registered");
        identity.registerBySig("uri", aliceSigner, deadline, sig);
    }

    function test_registerBySig_invalidSignatureReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        // Sign with the wrong key for aliceSigner's wallet.
        bytes memory sig = _signRegisterAgent(0xDEAD, "uri", aliceSigner, 0, deadline);

        vm.prank(bob);
        vm.expectRevert("invalid signature");
        identity.registerBySig("uri", aliceSigner, deadline, sig);
    }

    function test_registerBySig_replayAfterTransferPrevented() public {
        // Register, then transfer the NFT (clears agentOfWallet for the
        // signer), then try to replay the original signature. Without a
        // per-wallet nonce, the same signature would produce a fresh agentId.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRegisterAgent(ALICE_KEY, "uri", aliceSigner, 0, deadline);

        vm.prank(bob);
        uint256 agentId = identity.registerBySig("uri", aliceSigner, deadline, sig);

        // Transfer the NFT to bob — auto-clears agentOfWallet[aliceSigner].
        vm.prank(aliceSigner);
        identity.transferFrom(aliceSigner, bob, agentId);
        assertEq(identity.agentOfWallet(aliceSigner), 0, "reverse index cleared on transfer");

        // Replay should now fail because the nonce moved on.
        vm.prank(bob);
        vm.expectRevert("invalid signature");
        identity.registerBySig("uri", aliceSigner, deadline, sig);

        // Re-registering with a fresh signature for nonce=1 succeeds.
        bytes memory sig2 = _signRegisterAgent(ALICE_KEY, "uri", aliceSigner, 1, deadline);
        vm.prank(bob);
        uint256 agentId2 = identity.registerBySig("uri", aliceSigner, deadline, sig2);
        assertGt(agentId2, agentId);
        assertEq(identity.registrationNonce(aliceSigner), 2);
    }

    function test_registerBySig_mintsNFTToSignerNotRelayer() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRegisterAgent(ALICE_KEY, "uri", aliceSigner, 0, deadline);

        // Bob (the relayer) submits but should NOT receive the NFT.
        vm.prank(bob);
        uint256 agentId = identity.registerBySig("uri", aliceSigner, deadline, sig);

        assertEq(identity.ownerOf(agentId), aliceSigner);
        assertEq(identity.balanceOf(bob), 0);
    }

    // --- Single-agent-per-wallet invariant (P1-A) ------------------------

    function test_register_singleAgentPerWallet() public {
        vm.prank(alice);
        identity.register();

        // Same wallet, second register — must revert. Without this guard,
        // alice would own two agents, but the reverse index could only point
        // at one, breaking refund / EAS attest auth for the older agentId.
        vm.prank(alice);
        vm.expectRevert("wallet already has an agent");
        identity.register();

        // Same is true for the URI overload.
        vm.prank(alice);
        vm.expectRevert("wallet already has an agent");
        identity.register("ipfs://second");
    }

    function test_register_canRegisterAgainAfterUnsetAgentWallet() public {
        vm.prank(alice);
        uint256 firstId = identity.register();
        vm.prank(alice);
        identity.unsetAgentWallet(firstId);

        // Reverse index is clear; alice may now register a new agent.
        vm.prank(alice);
        uint256 secondId = identity.register();
        assertGt(secondId, firstId);
        assertEq(identity.agentOfWallet(alice), secondId);
    }

    function test_register_blocksRegisterBySigCollision() public {
        // Pre-register a wallet via plain register.
        vm.prank(aliceSigner);
        identity.register();

        // The wallet is mapped — registerBySig must also reject.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signRegisterAgent(ALICE_KEY, "uri", aliceSigner, 0, deadline);
        vm.prank(bob);
        vm.expectRevert("wallet already registered");
        identity.registerBySig("uri", aliceSigner, deadline, sig);
    }

    // --- setAgentWallet replay protection (M-1) --------------------------

    function test_setAgentWallet_signatureNotReplayableAfterUnset() public {
        vm.prank(alice);
        uint256 agentId = identity.register();

        address newWallet = vm.addr(0xB0B);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetAgentWallet(0xB0B, agentId, newWallet, deadline);

        vm.prank(alice);
        identity.setAgentWallet(agentId, newWallet, deadline, sig);
        assertEq(identity.getAgentWallet(agentId), newWallet);

        // Owner unsets the wallet (with intent to abandon the binding).
        vm.prank(alice);
        identity.unsetAgentWallet(agentId);
        assertEq(identity.agentOfWallet(newWallet), 0);

        // Replay the same sig within deadline — must fail because the nonce
        // has bumped. Without the nonce, the wallet would be silently
        // re-bound without renewed consent.
        vm.prank(alice);
        vm.expectRevert("invalid wallet signature");
        identity.setAgentWallet(agentId, newWallet, deadline, sig);

        // Fresh sig (with current nonce) succeeds.
        bytes memory sig2 = _signSetAgentWallet(0xB0B, agentId, newWallet, deadline);
        vm.prank(alice);
        identity.setAgentWallet(agentId, newWallet, deadline, sig2);
        assertEq(identity.getAgentWallet(agentId), newWallet);
    }

    // --- Admin 2-step (M-3) ----------------------------------------------

    function test_transferAdmin_twoStep() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        identity.transferAdmin(newAdmin);
        assertEq(identity.pendingAdmin(), newAdmin);
        assertEq(identity.admin(), admin, "admin unchanged before acceptance");

        // Random caller cannot accept.
        vm.prank(makeAddr("random"));
        vm.expectRevert("not pending admin");
        identity.acceptAdmin();

        vm.prank(newAdmin);
        identity.acceptAdmin();
        assertEq(identity.admin(), newAdmin);
        assertEq(identity.pendingAdmin(), address(0));
    }

    // --- Admin / UUPS ----------------------------------------------------

    function test_onlyAdminCanUpgrade() public {
        IdentityRegistry newImpl = new IdentityRegistry();
        vm.prank(alice);
        vm.expectRevert("not admin");
        identity.upgradeToAndCall(address(newImpl), "");
    }

    function test_initialize_zeroAdminReverts() public {
        IdentityRegistry impl = new IdentityRegistry();
        vm.expectRevert("zero admin");
        new ERC1967Proxy(address(impl), abi.encodeCall(IdentityRegistry.initialize, (address(0))));
    }

    // --- helpers ---------------------------------------------------------

    function _signSetAgentWallet(uint256 key, uint256 agentId, address newWallet, uint256 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        uint256 nonce = identity.walletRotationNonce(newWallet);
        bytes32 structHash =
            keccak256(abi.encode(identity.SET_AGENT_WALLET_TYPEHASH(), agentId, newWallet, nonce, deadline));
        bytes32 domainSep = _buildDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _signRegisterAgent(
        uint256 key,
        string memory agentURI,
        address agentWallet,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(identity.REGISTER_AGENT_TYPEHASH(), keccak256(bytes(agentURI)), agentWallet, nonce, deadline)
        );
        bytes32 domainSep = _buildDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _buildDomainSeparator() internal view returns (bytes32) {
        // OZ EIP712 domain: name, version, chainId, verifyingContract.
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Daski IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(identity)
            )
        );
    }
}
