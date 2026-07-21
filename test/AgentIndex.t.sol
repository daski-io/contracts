// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList, EmptySanctionsList, MalformedSanctionsList} from "./mocks/MockSanctionsList.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {IAgentIndex} from "../src/interfaces/IAgentIndex.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {AgentIndexSigner} from "./helpers/AgentIndexSigner.sol";

/// @dev Ports the retired IdentityRegistry.registerBySig coverage onto
///      AgentIndex.registerWithSig (canonical register → transfer → bind) and
///      exercises the verified reverse index (resolve/claim/unbind).
contract AgentIndexTest is Test {
    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    MockSanctionsList sanctions;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");

    uint256 constant WALLET_KEY = 0xA11CE;
    address wallet;

    string constant URI = "ipfs://agent";

    function setUp() public {
        wallet = vm.addr(WALLET_KEY);
        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();
        AgentIndex impl = new AgentIndex();
        agentIndex = AgentIndex(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(AgentIndex.initialize, (address(identity), address(sanctions), admin))
                )
            )
        );
    }

    function _sig(uint256 deadline) internal view returns (bytes memory) {
        return AgentIndexSigner.signRegister(vm, WALLET_KEY, agentIndex, URI, deadline);
    }

    function _assertResolved(address who, uint256 expected) internal view {
        (uint256 agentId, bool found) = agentIndex.resolve(who);
        assertTrue(found);
        assertEq(agentId, expected);
    }

    function _assertNotResolved(address who) internal view {
        (, bool found) = agentIndex.resolve(who);
        assertFalse(found);
    }

    // ── registerWithSig ──────────────────────────────────────────────

    function test_registerWithSig_happy() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sig(deadline);

        vm.prank(relayer);
        uint256 agentId = agentIndex.registerWithSig(URI, wallet, deadline, sig);

        // NFT minted on the canonical registry and handed to the wallet;
        // registration file set; binding resolves live.
        assertEq(identity.ownerOf(agentId), wallet, "NFT lands on the wallet, not the relayer");
        assertEq(identity.tokenURI(agentId), URI);
        _assertResolved(wallet, agentId);
        assertEq(agentIndex.registrationNonce(wallet), 1, "nonce bumped");
        // The canonical wallet is cleared when AgentIndex transfers the NFT.
        assertEq(identity.getAgentWallet(agentId), address(0));
    }

    function test_registerWithSigSanctionedSignerReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sig(deadline);
        sanctions.setSanctioned(wallet, true);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, wallet));
        agentIndex.registerWithSig(URI, wallet, deadline, sig);

        assertEq(agentIndex.registrationNonce(wallet), 0);
        _assertNotResolved(wallet);
    }

    function test_registerWithSigOracleFailureRevertsClosed() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sig(deadline);
        sanctions.setRevertChecks(true);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionsOracleUnavailable.selector, address(sanctions)));
        agentIndex.registerWithSig(URI, wallet, deadline, sig);
    }

    function test_registerWithSig_expiredDeadlineReverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sig(deadline);
        vm.prank(relayer);
        vm.expectRevert("signature expired");
        agentIndex.registerWithSig(URI, wallet, deadline, sig);
    }

    function test_registerWithSig_zeroWalletReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        vm.expectRevert("zero wallet");
        agentIndex.registerWithSig(URI, address(0), deadline, hex"00");
    }

    function test_registerWithSig_invalidSignatureReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = AgentIndexSigner.signRegister(vm, 0xBAD, agentIndex, URI, deadline);
        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        agentIndex.registerWithSig(URI, wallet, deadline, sig);
    }

    function test_registerWithSig_replayReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sig(deadline);
        vm.prank(relayer);
        agentIndex.registerWithSig(URI, wallet, deadline, sig);

        // Even after the wallet transfers the agent away (binding stale),
        // the consumed consent cannot be replayed — the nonce moved on.
        vm.prank(wallet);
        identity.transferFrom(wallet, makeAddr("elsewhere"), 0);
        _assertNotResolved(wallet);

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        agentIndex.registerWithSig(URI, wallet, deadline, sig);
    }

    function test_registerWithSig_alreadyBoundReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        agentIndex.registerWithSig(URI, wallet, deadline, _sig(deadline));

        // Fresh signature (nonce 1) but the wallet still controls its agent.
        bytes memory sig2 = _sig(deadline);
        vm.prank(relayer);
        vm.expectRevert("wallet already has an agent");
        agentIndex.registerWithSig(URI, wallet, deadline, sig2);
    }

    function test_registerWithSig_freshRegistrationAfterStaleBinding() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        uint256 first = agentIndex.registerWithSig(URI, wallet, deadline, _sig(deadline));

        // Wallet sells/moves the agent — stale binding must NOT block a
        // fresh registration (live check, not raw index read).
        vm.prank(wallet);
        identity.transferFrom(wallet, makeAddr("collector"), first);

        bytes memory sig2 = _sig(deadline); // signs with nonce 1
        vm.prank(relayer);
        uint256 second = agentIndex.registerWithSig(URI, wallet, deadline, sig2);
        assertGt(second, first);
        _assertResolved(wallet, second);
    }

    // ── claim / unbind / resolve ─────────────────────────────────────

    function test_claim_byOwner() public {
        // Bring-your-own canonical agent: registered directly, then claimed.
        vm.prank(wallet);
        uint256 agentId = identity.register(URI);
        _assertNotResolved(wallet);

        vm.prank(wallet);
        agentIndex.claim(agentId);
        _assertResolved(wallet, agentId);
    }

    function test_claim_byVerifiedAgentWallet() public {
        // Owner and payment wallet differ; the agentWallet may claim too.
        address owner = makeAddr("owner");
        address payWallet = makeAddr("payWallet");
        vm.prank(owner);
        uint256 agentId = identity.register(URI);
        identity.forceSetAgentWallet(agentId, payWallet);

        vm.prank(payWallet);
        agentIndex.claim(agentId);
        _assertResolved(payWallet, agentId);
    }

    function test_claimSanctionedAgentWalletReverts() public {
        address owner = makeAddr("sanctionsOwner");
        address payWallet = makeAddr("sanctionsPayWallet");
        vm.prank(owner);
        uint256 agentId = identity.register(URI);
        identity.forceSetAgentWallet(agentId, payWallet);
        sanctions.setSanctioned(payWallet, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, payWallet));
        agentIndex.claim(agentId);
    }

    function test_claim_unauthorizedReverts() public {
        vm.prank(wallet);
        uint256 agentId = identity.register(URI);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("not agent owner or wallet");
        agentIndex.claim(agentId);
    }

    function test_claim_nonexistentAgentReverts() public {
        vm.prank(wallet);
        vm.expectRevert("not agent owner or wallet");
        agentIndex.claim(999);
    }

    function test_unbind() public {
        vm.prank(wallet);
        uint256 agentId = identity.register(URI);
        vm.prank(wallet);
        agentIndex.claim(agentId);

        vm.prank(wallet);
        agentIndex.unbind();
        _assertNotResolved(wallet);

        vm.prank(wallet);
        vm.expectRevert("nothing bound");
        agentIndex.unbind();
    }

    function test_resolve_staleAfterTransfer_thenReclaimByNewOwner() public {
        vm.prank(wallet);
        uint256 agentId = identity.register(URI);
        vm.prank(wallet);
        agentIndex.claim(agentId);

        address newOwner = makeAddr("newOwner");
        vm.prank(wallet);
        identity.transferFrom(wallet, newOwner, agentId);

        // Old wallet no longer resolves; new owner claims and does.
        _assertNotResolved(wallet);
        vm.prank(newOwner);
        agentIndex.claim(agentId);
        _assertResolved(newOwner, agentId);
    }

    function test_resolve_viaAgentWalletBranch() public {
        // Binding survives an ownership move as long as the wallet remains
        // the agent's verified agentWallet.
        vm.prank(wallet);
        uint256 agentId = identity.register(URI);
        vm.prank(wallet);
        agentIndex.claim(agentId);

        // Owner moves the NFT but re-verifies the original wallet as the
        // agent's payment wallet.
        address newOwner = makeAddr("newOwner");
        vm.prank(wallet);
        identity.transferFrom(wallet, newOwner, agentId);
        identity.forceSetAgentWallet(agentId, wallet);

        _assertResolved(wallet, agentId);
    }

    // ── misc ─────────────────────────────────────────────────────────

    function test_onERC721Received_rejectsStrayTokens() public {
        MockCanonicalIdentityRegistry other = new MockCanonicalIdentityRegistry();
        vm.prank(wallet);
        uint256 strayId = other.register("stray");

        vm.prank(wallet);
        vm.expectRevert("unexpected token");
        other.safeTransferFrom(wallet, address(agentIndex), strayId);
    }

    function test_onERC721Received_rejectsStrayCanonicalToken() public {
        vm.prank(wallet);
        uint256 strayId = identity.register("stray");

        vm.prank(wallet);
        vm.expectRevert("unexpected transfer");
        identity.safeTransferFrom(wallet, address(agentIndex), strayId);
    }

    function test_getIdentityRegistry() public view {
        assertEq(agentIndex.getIdentityRegistry(), address(identity));
    }

    function test_initialize_zeroIdentityReverts() public {
        AgentIndex impl = new AgentIndex();
        vm.expectRevert("zero identity");
        new ERC1967Proxy(address(impl), abi.encodeCall(AgentIndex.initialize, (address(0), address(sanctions), admin)));
    }

    function test_initializeRejectsOracleWithoutCode() public {
        address missingOracle = makeAddr("missingOracle");
        AgentIndex impl = new AgentIndex();
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionsOracleUnavailable.selector, missingOracle));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIndex.initialize, (address(identity), missingOracle, admin))
        );
    }

    function test_initializeRejectsEmptyOracleResponse() public {
        EmptySanctionsList empty = new EmptySanctionsList();
        AgentIndex impl = new AgentIndex();
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionsOracleUnavailable.selector, address(empty)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIndex.initialize, (address(identity), address(empty), admin))
        );
    }

    function test_initializeRejectsMalformedOracleResponse() public {
        MalformedSanctionsList malformed = new MalformedSanctionsList();
        AgentIndex impl = new AgentIndex();
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionsOracleUnavailable.selector, address(malformed)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIndex.initialize, (address(identity), address(malformed), admin))
        );
    }

    function test_registeredEventEmitted() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sig(deadline);
        vm.expectEmit(true, true, false, true, address(agentIndex));
        emit IAgentIndex.AgentRegistered(0, wallet, URI);
        vm.prank(relayer);
        agentIndex.registerWithSig(URI, wallet, deadline, sig);
    }
}
