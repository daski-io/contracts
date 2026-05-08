// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {
    AttestationRequest,
    AttestationRequestData,
    DelegatedAttestationRequest,
    RevocationRequest,
    RevocationRequestData,
    Signature
} from "../src/interfaces/IEAS.sol";

contract ReputationStorageTest is Test {
    IdentityRegistry identity;
    ProviderRegistry registry;
    PaymentRouter router;
    X402Adapter adapter;
    ReputationStorage reputation;
    MockUSDC usdc;
    MockEAS eas;

    bytes32 outcomeSchemaUid;
    bytes32 confirmationSchemaUid;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    uint256 constant BUYER_KEY = 0xBEEF;
    address buyer;
    address provider = makeAddr("provider");
    address unauthorized = makeAddr("unauthorized");
    address relayer = makeAddr("relayer");

    uint256 providerAgentId;
    uint256 buyerAgentId;
    uint256 paymentId;

    event ReputationRefunded(uint256 indexed paymentId, uint256 amountToBuyer, uint256 cumulativeRefunded);

    function setUp() public {
        buyer = vm.addr(BUYER_KEY);
        usdc = new MockUSDC();
        eas = new MockEAS();

        IdentityRegistry idImpl = new IdentityRegistry();
        identity = IdentityRegistry(
            address(new ERC1967Proxy(address(idImpl), abi.encodeCall(IdentityRegistry.initialize, (admin))))
        );

        ProviderRegistry regImpl = new ProviderRegistry();
        registry = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(
                        ProviderRegistry.initialize, (address(identity), address(usdc), treasury, 1_000_000, admin)
                    )
                )
            )
        );

        PaymentRouter routerImpl = new PaymentRouter();
        router = PaymentRouter(
            address(
                new ERC1967Proxy(
                    address(routerImpl),
                    abi.encodeCall(
                        PaymentRouter.initialize, (address(identity), address(registry), treasury, 500, admin)
                    )
                )
            )
        );

        X402Adapter aImpl = new X402Adapter();
        adapter = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(aImpl), abi.encodeCall(X402Adapter.initialize, (address(router), address(identity), admin))
                )
            )
        );

        vm.prank(admin);
        router.setAdapter(address(adapter), true);
        vm.prank(admin);
        router.setAcceptedToken(address(usdc), true);

        ReputationStorage repImpl = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(repImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(identity), address(router), admin))
                )
            )
        );

        // Register EAS schemas bound to this resolver + wire the resolver.
        outcomeSchemaUid =
            eas.register("uint256 paymentId,uint8 outcome,uint256 fulfillmentTime", address(reputation), false);
        confirmationSchemaUid = eas.register("uint256 paymentId,uint8 confirmation", address(reputation), true);
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchemaUid);
        reputation.setConfirmationSchema(confirmationSchemaUid);
        router.setReputationStorage(address(reputation));
        vm.stopPrank();

        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example.com/agent.json");

        usdc.mint(provider, 1_000_000);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1_000_000);
        registry.register(providerAgentId);
        vm.stopPrank();

        vm.prank(buyer);
        buyerAgentId = identity.register();
        usdc.mint(buyer, 100e6);
        paymentId = _payAsBuyer(100e6, keccak256("service-1"));
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// @dev EIP-3009 nonce is bound to (serviceRef, providerAgentId) per
    ///      X402Adapter — see contract NatSpec.
    function _payAsBuyer(uint256 amount, bytes32 serviceRef) internal returns (uint256) {
        bytes32 boundNonce = keccak256(abi.encode(serviceRef, providerAgentId));
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(usdc), buyer, address(router), amount, 0, block.timestamp + 1 hours, boundNonce
        );
        vm.prank(relayer);
        return adapter.settle(address(usdc), amount, serviceRef, providerAgentId, auth);
    }

    function _outcomeReq(uint256 pid, ReputationStorage.TransactionOutcome o, uint256 ft)
        internal
        view
        returns (AttestationRequest memory)
    {
        return AttestationRequest({
            schema: outcomeSchemaUid,
            data: AttestationRequestData({
                recipient: address(0),
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: abi.encode(pid, uint8(o), ft),
                value: 0
            })
        });
    }

    function _confirmReq(uint256 pid, ReputationStorage.BuyerConfirmation c, bytes32 refUid)
        internal
        view
        returns (AttestationRequest memory)
    {
        return AttestationRequest({
            schema: confirmationSchemaUid,
            data: AttestationRequestData({
                recipient: address(0),
                expirationTime: 0,
                revocable: true,
                refUID: refUid,
                data: abi.encode(pid, uint8(c)),
                value: 0
            })
        });
    }

    function _delegatedConfirm(address attester, uint256 pid, ReputationStorage.BuyerConfirmation c, bytes32 refUid)
        internal
        view
        returns (DelegatedAttestationRequest memory)
    {
        return DelegatedAttestationRequest({
            schema: confirmationSchemaUid,
            data: AttestationRequestData({
                recipient: address(0),
                expirationTime: 0,
                revocable: true,
                refUID: refUid,
                data: abi.encode(pid, uint8(c)),
                value: 0
            }),
            signature: Signature({v: 0, r: bytes32(0), s: bytes32(0)}),
            attester: attester,
            deadline: type(uint64).max
        });
    }

    // ── Outcome via EAS ─────────────────────────────────────────────────

    function test_recordOutcomeHappyPath() public {
        // Advance time so the derived fulfillmentTime is non-zero. The
        // attested value (99_999) is intentionally a sentinel that does NOT
        // match the warp delta — the resolver MUST ignore it and derive
        // from PaymentRouter.paidAt instead. If the test ever asserts
        // against the attested number, the gameability fix has regressed.
        uint256 elapsed = 600;
        vm.warp(block.timestamp + elapsed);

        vm.prank(provider);
        bytes32 uid = eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 99_999));
        assertTrue(uid != bytes32(0), "uid returned");

        ReputationStorage.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertTrue(rec.outcomeRecorded);
        assertEq(uint256(rec.outcome), uint256(ReputationStorage.TransactionOutcome.Completed));
        assertEq(rec.fulfillmentTime, elapsed, "fulfillmentTime is derived from paidAt, not attested");
        assertEq(rec.providerAgentId, providerAgentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(reputation.completedCount(providerAgentId), 1);
        assertEq(reputation.buyerTransactionCount(buyerAgentId), 1);
    }

    function test_recordOutcomeUnauthorizedReverts() public {
        // Unauthorized attester has no registered identity at all.
        vm.prank(unauthorized);
        vm.expectRevert("no identity");
        eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));

        // Buyer has an identity but is not the provider for this payment.
        vm.prank(buyer);
        vm.expectRevert("not provider for this payment");
        eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));
    }

    function test_recordOutcomeDoubleReverts() public {
        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));

        vm.prank(provider);
        vm.expectRevert("outcome already recorded");
        eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));
    }

    function test_recordOutcomeRevocationRejected() public {
        vm.prank(provider);
        // The outcome schema is NOT revocable at the EAS level; even if it
        // were, the resolver would reject onRevoke. Here we assert EAS's
        // own schema-revocable check fires first.
        bytes32 uid = eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));

        vm.prank(provider);
        vm.expectRevert("schema not revocable");
        eas.revoke(RevocationRequest({schema: outcomeSchemaUid, data: RevocationRequestData({uid: uid, value: 0})}));
    }

    // ── Confirmation via EAS (direct) ───────────────────────────────────

    function test_submitConfirmationHappyPath() public {
        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));

        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));

        ReputationStorage.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorage.BuyerConfirmation.Confirmed));
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 1);
    }

    function test_submitConfirmationPendingReverts() public {
        vm.prank(buyer);
        vm.expectRevert("binary confirmation only");
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Pending, bytes32(0)));
    }

    function test_submitConfirmationUnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert("no identity");
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));

        vm.prank(provider);
        vm.expectRevert("not buyer for this payment");
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));
    }

    // ── Confirmation revision via refUID (EAS-idiomatic) ────────────────

    function test_confirmationRevisionRebalancesCounters() public {
        vm.prank(buyer);
        bytes32 firstUid = eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 1);

        // Now revise to NotConfirmed via refUID (the EAS-idiomatic way).
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.NotConfirmed, firstUid));

        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 0);
        assertEq(reputation.notConfirmedCount(providerAgentId), 1);
        assertEq(reputation.buyerNotConfirmedCount(buyerAgentId), 1);

        ReputationStorage.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorage.BuyerConfirmation.NotConfirmed));
    }

    function test_confirmationSecondWithoutRefUIDReverts() public {
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));

        // Second attestation without refUID is ambiguous — resolver rejects.
        vm.prank(buyer);
        vm.expectRevert("must ref prior confirmation");
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.NotConfirmed, bytes32(0)));
    }

    function test_confirmationRevisionChainOfThree() public {
        vm.prank(buyer);
        bytes32 u1 = eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));
        vm.prank(buyer);
        bytes32 u2 = eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.NotConfirmed, u1));
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, u2));

        // Net: +1 Confirmed, 0 NotConfirmed.
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.notConfirmedCount(providerAgentId), 0);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 1);
        assertEq(reputation.buyerNotConfirmedCount(buyerAgentId), 0);
    }

    function test_confirmationRefToSuperseded_reverts() public {
        vm.prank(buyer);
        bytes32 u1 = eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.NotConfirmed, u1));

        // u1 has been superseded (mapping cleared). A third attestation that
        // still claims u1 as its refUID must fail — the resolver cannot
        // double-decrement.
        vm.prank(buyer);
        vm.expectRevert("refUID is not a tracked confirmation");
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, u1));
    }

    // ── H-1: refUID must belong to the same paymentId ───────────────────

    function test_confirmationRefUidFromOtherPayment_reverts() public {
        // Buyer is the buyer for paymentId (set up in setUp). They confirm.
        vm.prank(buyer);
        bytes32 victimUid =
            eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);

        // Set up a SECOND payment with a SECOND provider (provider2) and a
        // SECOND buyer (buyer2). buyer2 then tries to attest a confirmation
        // for paymentId2 referencing victimUid (buyer's confirmation for
        // paymentId on provider1). Pre-fix, this would decrement
        // confirmedCount[provider2] (wrong provider!) and orphan victimUid.
        uint256 attackerKey = 0xDEAD;
        address buyer2 = vm.addr(attackerKey);
        address provider2 = makeAddr("provider2");

        vm.prank(provider2);
        uint256 provider2AgentId = identity.register("https://provider2.example/agent.json");
        usdc.mint(provider2, 1_000_000);
        vm.startPrank(provider2);
        usdc.approve(address(registry), 1_000_000);
        registry.register(provider2AgentId);
        vm.stopPrank();

        vm.prank(buyer2);
        identity.register();
        usdc.mint(buyer2, 100e6);

        // Pay 100 USDC to provider2 from buyer2. Nonce is bound to
        // (serviceRef, providerAgentId) per X402Adapter.
        bytes32 attackSvc = keccak256("attack-svc");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm,
            attackerKey,
            address(usdc),
            buyer2,
            address(router),
            100e6,
            0,
            block.timestamp + 1 hours,
            keccak256(abi.encode(attackSvc, provider2AgentId))
        );
        vm.prank(relayer);
        uint256 paymentId2 = adapter.settle(address(usdc), 100e6, attackSvc, provider2AgentId, auth);

        // Attack attempt: buyer2 attests Confirmed for paymentId2 with refUID
        // pointing at victimUid (which is for paymentId on provider1).
        vm.prank(buyer2);
        vm.expectRevert("refUID belongs to different payment");
        eas.attest(_confirmReq(paymentId2, ReputationStorage.BuyerConfirmation.Confirmed, victimUid));

        // Defenses held: provider1's count untouched, victimUid still tracked,
        // provider2 has no confirmation yet.
        assertEq(reputation.confirmedCount(providerAgentId), 1, "victim provider count untouched");
        assertEq(reputation.confirmedCount(provider2AgentId), 0, "attacker did not credit themselves");
        assertEq(
            uint256(reputation.confirmationByUid(victimUid)),
            uint256(ReputationStorage.BuyerConfirmation.Confirmed),
            "victim UID still tracked"
        );

        // And the legitimate buyer can still revise their own UID afterwards.
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.NotConfirmed, victimUid));
        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.notConfirmedCount(providerAgentId), 1);
    }

    // ── Confirmation via delegated attestation (relayer submits) ────────

    function test_delegatedConfirmationCreditsBuyer() public {
        // Relayer submits attestByDelegation on behalf of the buyer. The
        // mock skips sig verification; the resolver still enforces
        // "attester's wallet maps to the expected buyer".
        vm.prank(relayer);
        eas.attestByDelegation(
            _delegatedConfirm(buyer, paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0))
        );
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 1);
    }

    function test_delegatedConfirmationAttesterMustBeBuyer() public {
        vm.prank(relayer);
        vm.expectRevert("not buyer for this payment");
        eas.attestByDelegation(
            _delegatedConfirm(provider, paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0))
        );
    }

    // ── Confirmation revocation decrements counters ─────────────────────

    function test_confirmationRevocationDecrements() public {
        vm.prank(buyer);
        bytes32 uid = eas.attest(_confirmReq(paymentId, ReputationStorage.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);

        vm.prank(buyer);
        eas.revoke(
            RevocationRequest({schema: confirmationSchemaUid, data: RevocationRequestData({uid: uid, value: 0})})
        );
        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 0);

        ReputationStorage.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorage.BuyerConfirmation.Pending));
    }

    // ── EAS-only guard ─────────────────────────────────────────────────

    function test_nonEASCallerRejected() public {
        // A non-EAS attempting to call the resolver directly is rejected.
        // Build a minimal Attestation and try calling attest() directly —
        // the resolver's onlyEAS modifier fires before we get to the
        // payload decode.
        //
        // We use a low-level .call and assert it returns false + the
        // expected revert string. vm.expectRevert cannot be used here
        // because .call swallows the revert into a boolean.
        bytes memory callData = abi.encodeWithSignature(
            "attest((bytes32,bytes32,uint64,uint64,uint64,bytes32,address,address,bool,bytes))",
            bytes32(uint256(1)),
            outcomeSchemaUid,
            uint64(block.timestamp),
            uint64(0),
            uint64(0),
            bytes32(0),
            address(0),
            buyer,
            false,
            abi.encode(paymentId, uint8(0), uint256(3600))
        );

        vm.prank(buyer);
        (bool success, bytes memory ret) = address(reputation).call(callData);
        assertTrue(!success, "direct call must fail");
        // Extract the revert reason (Error(string)) from returndata.
        //   4 bytes     selector (0x08c379a0)
        //   32 bytes    offset
        //   32 bytes    length
        //   N bytes     message, right-padded to a 32-byte boundary
        // Use the encoded length (NOT ret.length - 68) so we don't include
        // the trailing zero padding when hashing.
        require(ret.length >= 68, "no revert reason returned");
        uint256 strLen;
        assembly {
            strLen := mload(add(ret, 0x44)) // 0x20 (length prefix) + 4 + 32 = 0x44
        }
        bytes memory reasonBytes = new bytes(strLen);
        for (uint256 i = 0; i < strLen; i++) {
            reasonBytes[i] = ret[68 + i];
        }
        assertEq(keccak256(abi.encodePacked(string(reasonBytes))), keccak256("not EAS"), "wrong revert reason");
    }

    // ── Refund mirror (unchanged) ───────────────────────────────────────

    function test_recordRefundViaRouter() public {
        vm.prank(provider);
        usdc.approve(address(router), 50e6);

        vm.expectEmit(true, true, true, true, address(reputation));
        emit ReputationRefunded(paymentId, 30e6, 30e6);
        vm.prank(provider);
        router.refund(paymentId, 30e6);

        assertEq(reputation.refundedAmount(paymentId), 30e6);
        assertEq(reputation.getRefundedAmount(paymentId), 30e6);
    }

    function test_recordRefundCumulative() public {
        vm.prank(provider);
        usdc.approve(address(router), 90e6);

        vm.prank(provider);
        router.refund(paymentId, 40e6);
        assertEq(reputation.refundedAmount(paymentId), 40e6);

        vm.prank(provider);
        router.refund(paymentId, 50e6);
        assertEq(reputation.refundedAmount(paymentId), 90e6);
    }

    function test_recordRefundOnlyRouterReverts() public {
        vm.prank(provider);
        vm.expectRevert("not payment router");
        reputation.recordRefund(paymentId, 10e6);

        vm.prank(admin);
        vm.expectRevert("not payment router");
        reputation.recordRefund(paymentId, 10e6);
    }

    function test_refundOrthogonalToOutcome() public {
        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorage.TransactionOutcome.Completed, 3600));

        vm.prank(provider);
        usdc.approve(address(router), 20e6);
        vm.prank(provider);
        router.refund(paymentId, 20e6);

        ReputationStorage.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.outcome), uint256(ReputationStorage.TransactionOutcome.Completed));
        assertTrue(rec.outcomeRecorded);
        assertEq(reputation.refundedAmount(paymentId), 20e6);
    }

    function test_setPaymentRouterAdmin() public {
        address fake = makeAddr("fakeRouter");
        vm.prank(admin);
        reputation.setPaymentRouter(fake);
        assertEq(address(reputation.paymentRouter()), fake);

        vm.prank(fake);
        reputation.recordRefund(paymentId, 5e6);
        assertEq(reputation.refundedAmount(paymentId), 5e6);
    }

    function test_setPaymentRouterOnlyAdmin() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setPaymentRouter(address(0x1));
    }

    function test_setPaymentRouterZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert("zero router");
        reputation.setPaymentRouter(address(0));
    }

    function test_setEASOnlyAdmin() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setEAS(address(0x1));
    }

    function test_setSchemaOnlyAdmin() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setOutcomeSchema(bytes32(uint256(1)));
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setConfirmationSchema(bytes32(uint256(1)));
    }
}
