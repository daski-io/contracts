// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";

contract ReputationStorageTest is Test {
    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    ProviderRegistry registry;
    ServiceRegistry services;
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
    bytes32 serviceId;
    uint256 paymentId;
    mapping(uint256 => address) providerRecipients;

    event ReputationRefunded(
        uint256 indexed paymentId, bytes32 indexed serviceId, uint256 amountToBuyer, uint256 cumulativeRefunded
    );

    function setUp() public {
        buyer = vm.addr(BUYER_KEY);
        usdc = new MockUSDC();
        eas = new MockEAS();

        identity = new MockCanonicalIdentityRegistry();
        AgentIndex aiImpl = new AgentIndex();
        agentIndex = AgentIndex(
            address(
                new ERC1967Proxy(address(aiImpl), abi.encodeCall(AgentIndex.initialize, (address(identity), admin)))
            )
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

        ServiceRegistry sregImpl = new ServiceRegistry();
        services = ServiceRegistry(
            address(
                new ERC1967Proxy(
                    address(sregImpl),
                    abi.encodeCall(ServiceRegistry.initialize, (address(identity), address(registry), admin))
                )
            )
        );

        PaymentRouter routerImpl = new PaymentRouter();
        router = PaymentRouter(
            address(
                new ERC1967Proxy(
                    address(routerImpl),
                    abi.encodeCall(
                        PaymentRouter.initialize,
                        (address(identity), address(registry), address(services), treasury, 500, admin)
                    )
                )
            )
        );

        X402Adapter aImpl = new X402Adapter();
        adapter = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(X402Adapter.initialize, (address(router), address(agentIndex), admin))
                )
            )
        );

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
        outcomeSchemaUid = eas.register("uint256 paymentId,uint8 outcome", address(reputation), false);
        confirmationSchemaUid = eas.register("uint256 paymentId,uint8 confirmation", address(reputation), true);
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchemaUid);
        reputation.setConfirmationSchema(confirmationSchemaUid);
        router.setReputationStorage(address(reputation));
        router.setAdapter(address(adapter), true);
        router.setAcceptedToken(address(usdc), true);
        vm.stopPrank();

        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example.com/agent.json");
        // Keep the provider wallet explicit in this fixture; it also makes
        // `provider` the outcome attester via the agentWallet branch.
        identity.forceSetAgentWallet(providerAgentId, provider);

        usdc.mint(provider, 1_000_000);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1_000_000);
        registry.register(providerAgentId);
        vm.stopPrank();

        vm.prank(provider);
        serviceId = services.registerService(providerAgentId, "skill", "1", "u", address(0));

        vm.prank(buyer);
        buyerAgentId = identity.register();
        // The adapter resolves the buyer through the AgentIndex — bind it.
        vm.prank(buyer);
        agentIndex.claim(buyerAgentId);
        usdc.mint(buyer, 100e6);
        paymentId = _payAsBuyer(100e6, keccak256("service-1"), serviceId);
        providerRecipients[paymentId] = provider;
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// @dev EIP-3009 nonce is bound to (serviceRef, providerAgentId, serviceId)
    ///      per X402Adapter — see contract NatSpec.
    function _payAsBuyer(uint256 amount, bytes32 serviceRef, bytes32 svcId) internal returns (uint256) {
        bytes32 boundNonce = keccak256(abi.encode(serviceRef, providerAgentId, svcId));
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(usdc), buyer, address(router), amount, 0, block.timestamp + 1 hours, boundNonce
        );
        vm.prank(relayer);
        return adapter.settle(address(usdc), amount, serviceRef, providerAgentId, svcId, auth);
    }

    function _outcomeReq(uint256 pid, ReputationStorageBase.TransactionOutcome o)
        internal
        view
        returns (AttestationRequest memory)
    {
        return AttestationRequest({
            schema: outcomeSchemaUid,
            data: AttestationRequestData({
                recipient: _providerRecipient(pid),
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: abi.encode(pid, uint8(o)),
                value: 0
            })
        });
    }

    function _confirmReq(uint256 pid, ReputationStorageBase.BuyerConfirmation c, bytes32 refUid)
        internal
        view
        returns (AttestationRequest memory)
    {
        return AttestationRequest({
            schema: confirmationSchemaUid,
            data: AttestationRequestData({
                recipient: _providerRecipient(pid),
                expirationTime: 0,
                revocable: true,
                refUID: refUid,
                data: abi.encode(pid, uint8(c)),
                value: 0
            })
        });
    }

    function _providerRecipient(uint256 pid) internal view returns (address) {
        return providerRecipients[pid];
    }

    // ── Outcome via EAS ─────────────────────────────────────────────────

    function test_recordOutcomeHappyPath() public {
        uint256 elapsed = 600;
        vm.warp(block.timestamp + elapsed);

        vm.prank(provider);
        bytes32 uid = eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));
        assertTrue(uid != bytes32(0), "uid returned");

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertTrue(rec.outcomeRecorded);
        assertEq(uint256(rec.outcome), uint256(ReputationStorageBase.TransactionOutcome.Completed));
        assertEq(rec.outcomeAttestationDelay, elapsed, "attestation delay is derived from paidAt");
        assertEq(rec.providerAgentId, providerAgentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(rec.serviceId, serviceId, "serviceId stamped on record");
        assertEq(reputation.completedCount(providerAgentId), 1);
        assertEq(reputation.completedByService(serviceId), 1, "per-service counter incremented");
        assertEq(reputation.buyerTransactionCount(buyerAgentId), 1);
    }

    function test_recordOutcomeUnauthorizedReverts() public {
        // The attester must control the payment's provider agent on the
        // canonical registry (agentWallet or owner) — a wallet with no
        // relation to the agent fails the same check as the wrong party.
        vm.prank(unauthorized);
        vm.expectRevert("not provider for this payment");
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(buyer);
        vm.expectRevert("not provider for this payment");
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));
    }

    function test_outcomeRejectsWrongRecipient() public {
        AttestationRequest memory request = _outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed);
        request.data.recipient = unauthorized;

        vm.prank(provider);
        vm.expectRevert("wrong reputation recipient");
        eas.attest(request);
    }

    function test_providerTransferDoesNotTransferHistoricalAttestationAuthority() public {
        address newOwner = makeAddr("newProviderOwner");
        vm.prank(provider);
        identity.transferFrom(provider, newOwner, providerAgentId);

        vm.prank(newOwner);
        vm.expectRevert("not provider for this payment");
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));
        assertTrue(reputation.getRecord(paymentId).outcomeRecorded);
    }

    function test_recordOutcomeDoubleReverts() public {
        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(provider);
        vm.expectRevert("outcome already recorded");
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));
    }

    function test_recordOutcomeRevocationRejected() public {
        vm.prank(provider);
        bytes32 uid = eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(provider);
        vm.expectRevert("schema not revocable");
        eas.revoke(RevocationRequest({schema: outcomeSchemaUid, data: RevocationRequestData({uid: uid, value: 0})}));
    }

    // ── Confirmation via EAS (direct) ───────────────────────────────────

    function test_submitConfirmationHappyPath() public {
        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorageBase.BuyerConfirmation.Confirmed));
        assertEq(rec.serviceId, serviceId);
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.confirmedByService(serviceId), 1);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 1);
    }

    function test_submitConfirmationPendingReverts() public {
        vm.prank(buyer);
        vm.expectRevert("binary confirmation only");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Pending, bytes32(0)));
    }

    function test_submitConfirmationUnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert("not buyer for this payment");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        vm.prank(provider);
        vm.expectRevert("not buyer for this payment");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
    }

    function test_confirmationRejectsWrongRecipient() public {
        AttestationRequest memory request =
            _confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0));
        request.data.recipient = unauthorized;

        vm.prank(buyer);
        vm.expectRevert("wrong reputation recipient");
        eas.attest(request);
    }

    function test_buyerTransferDoesNotTransferHistoricalConfirmationAuthority() public {
        address newOwner = makeAddr("newBuyerOwner");
        vm.prank(buyer);
        identity.transferFrom(buyer, newOwner, buyerAgentId);

        vm.prank(newOwner);
        vm.expectRevert("not buyer for this payment");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(
            uint256(reputation.getRecord(paymentId).confirmation),
            uint256(ReputationStorageBase.BuyerConfirmation.Confirmed)
        );
    }

    // ── Confirmation revision via refUID (EAS-idiomatic) ────────────────

    function test_confirmationRevisionRebalancesCounters() public {
        vm.prank(buyer);
        bytes32 firstUid =
            eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.confirmedByService(serviceId), 1);

        // Now revise to NotConfirmed via refUID (the EAS-idiomatic way).
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.NotConfirmed, firstUid));

        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.confirmedByService(serviceId), 0);
        assertEq(reputation.notConfirmedCount(providerAgentId), 1);
        assertEq(reputation.notConfirmedByService(serviceId), 1);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 0);
        assertEq(reputation.buyerNotConfirmedCount(buyerAgentId), 1);

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorageBase.BuyerConfirmation.NotConfirmed));
    }

    function test_confirmationSecondWithoutRefUIDReverts() public {
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        vm.prank(buyer);
        vm.expectRevert("must ref prior confirmation");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.NotConfirmed, bytes32(0)));
    }

    function test_confirmationRevisionChainOfThree() public {
        vm.prank(buyer);
        bytes32 u1 = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        vm.prank(buyer);
        bytes32 u2 = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.NotConfirmed, u1));
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, u2));

        // Net: +1 Confirmed, 0 NotConfirmed.
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.confirmedByService(serviceId), 1);
        assertEq(reputation.notConfirmedCount(providerAgentId), 0);
        assertEq(reputation.notConfirmedByService(serviceId), 0);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 1);
        assertEq(reputation.buyerNotConfirmedCount(buyerAgentId), 0);
    }

    function test_confirmationRefToSuperseded_reverts() public {
        vm.prank(buyer);
        bytes32 u1 = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.NotConfirmed, u1));

        vm.prank(buyer);
        vm.expectRevert("refUID is not a tracked confirmation");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, u1));
    }

    function test_confirmationRefUidFromOtherPayment_reverts() public {
        vm.prank(buyer);
        bytes32 victimUid =
            eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);

        uint256 attackerKey = 0xDEAD;
        address buyer2 = vm.addr(attackerKey);
        address provider2 = makeAddr("provider2");

        vm.prank(provider2);
        uint256 provider2AgentId = identity.register("https://provider2.example/agent.json");
        identity.forceSetAgentWallet(provider2AgentId, provider2);
        usdc.mint(provider2, 1_000_000);
        vm.startPrank(provider2);
        usdc.approve(address(registry), 1_000_000);
        registry.register(provider2AgentId);
        vm.stopPrank();
        vm.prank(provider2);
        bytes32 svc2 = services.registerService(provider2AgentId, "skill", "1", "u", address(0));

        vm.prank(buyer2);
        uint256 buyer2AgentId = identity.register();
        vm.prank(buyer2);
        agentIndex.claim(buyer2AgentId);
        usdc.mint(buyer2, 100e6);

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
            keccak256(abi.encode(attackSvc, provider2AgentId, svc2))
        );
        vm.prank(relayer);
        uint256 paymentId2 = adapter.settle(address(usdc), 100e6, attackSvc, provider2AgentId, svc2, auth);
        providerRecipients[paymentId2] = provider2;

        vm.prank(buyer2);
        vm.expectRevert("refUID belongs to different payment");
        eas.attest(_confirmReq(paymentId2, ReputationStorageBase.BuyerConfirmation.Confirmed, victimUid));

        assertEq(reputation.confirmedCount(providerAgentId), 1, "victim provider count untouched");
        assertEq(reputation.confirmedCount(provider2AgentId), 0, "attacker did not credit themselves");
        assertEq(
            uint256(reputation.confirmationByUid(victimUid)),
            uint256(ReputationStorageBase.BuyerConfirmation.Confirmed),
            "victim UID still tracked"
        );

        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.NotConfirmed, victimUid));
        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.notConfirmedCount(providerAgentId), 1);
    }

    // ── Confirmation revocation decrements counters ─────────────────────

    function test_confirmationRevocationDecrements() public {
        vm.prank(buyer);
        bytes32 uid = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);
        assertEq(reputation.confirmedByService(serviceId), 1);

        vm.prank(buyer);
        eas.revoke(
            RevocationRequest({schema: confirmationSchemaUid, data: RevocationRequestData({uid: uid, value: 0})})
        );
        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.confirmedByService(serviceId), 0);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 0);

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorageBase.BuyerConfirmation.Pending));
    }

    // ── EAS-only guard ─────────────────────────────────────────────────

    function test_nonEASCallerRejected() public {
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
        require(ret.length >= 68, "no revert reason returned");
        uint256 strLen;
        assembly {
            strLen := mload(add(ret, 0x44))
        }
        bytes memory reasonBytes = new bytes(strLen);
        for (uint256 i = 0; i < strLen; i++) {
            reasonBytes[i] = ret[68 + i];
        }
        assertEq(keccak256(abi.encodePacked(string(reasonBytes))), keccak256("not EAS"), "wrong revert reason");
    }

    function test_paymentIsCountedBeforeProviderOutcome() public view {
        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(rec.paymentId, paymentId);
        assertFalse(rec.outcomeRecorded);
        assertEq(reputation.providerTransactionCount(providerAgentId), 1);
        assertEq(reputation.serviceTransactionCount(serviceId), 1);
        assertEq(reputation.buyerTransactionCount(buyerAgentId), 1);
    }

    function test_expiringAttestationRejected() public {
        AttestationRequest memory request = _outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed);
        request.data.expirationTime = uint64(block.timestamp + 1 days);

        vm.prank(provider);
        vm.expectRevert("expiring attestations unsupported");
        eas.attest(request);
    }

    // ── Refund mirror (per-service dimension) ───────────────────────────

    function test_recordRefundViaRouter() public {
        vm.prank(provider);
        usdc.approve(address(router), 50e6);

        vm.expectEmit(true, true, true, true, address(reputation));
        emit ReputationRefunded(paymentId, serviceId, 30e6, 30e6);
        vm.prank(provider);
        router.refund(paymentId, 30e6);

        assertEq(reputation.refundedAmount(paymentId), 30e6);
        assertEq(reputation.refundedAmountByService(serviceId), 30e6);
        assertEq(reputation.getRefundedAmount(paymentId), 30e6);
    }

    function test_recordRefundCumulative() public {
        vm.prank(provider);
        usdc.approve(address(router), 90e6);

        vm.prank(provider);
        router.refund(paymentId, 40e6);
        assertEq(reputation.refundedAmount(paymentId), 40e6);
        assertEq(reputation.refundedAmountByService(serviceId), 40e6);

        vm.prank(provider);
        router.refund(paymentId, 50e6);
        assertEq(reputation.refundedAmount(paymentId), 90e6);
        assertEq(reputation.refundedAmountByService(serviceId), 90e6);
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
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(provider);
        usdc.approve(address(router), 20e6);
        vm.prank(provider);
        router.refund(paymentId, 20e6);

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.outcome), uint256(ReputationStorageBase.TransactionOutcome.Completed));
        assertTrue(rec.outcomeRecorded);
        assertEq(reputation.refundedAmount(paymentId), 20e6);
        assertEq(reputation.refundedAmountByService(serviceId), 20e6);
    }

    function test_setPaymentRouterAdminBeforeRecords() public {
        ReputationStorage freshImpl = new ReputationStorage();
        ReputationStorage fresh = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(identity), address(router), admin))
                )
            )
        );
        address fake = address(new PaymentRouter());
        vm.prank(admin);
        fresh.setPaymentRouter(fake);
        assertEq(address(fresh.paymentRouter()), fake);
    }

    function test_setPaymentRouter_revertsWhenRecordsExist() public {
        // Recording any outcome populates recordIds. After that the router
        // pointer is frozen: re-pointing at a router whose paymentIds restart
        // at 1 would collide with existing records and corrupt counters, so the
        // guard forbids the swap and forces a full-stack redeploy instead.
        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));
        assertEq(reputation.getRecordCount(), 1, "record created");

        vm.prank(admin);
        vm.expectRevert("records exist");
        reputation.setPaymentRouter(makeAddr("fakeRouter"));
    }

    function test_setPaymentRouterOnlyAdmin() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setPaymentRouter(address(0x1));
    }

    function test_setPaymentRouterZeroReverts() public {
        ReputationStorage freshImpl = new ReputationStorage();
        ReputationStorage fresh = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(identity), address(router), admin))
                )
            )
        );
        vm.prank(admin);
        vm.expectRevert("zero router");
        fresh.setPaymentRouter(address(0));
    }

    function test_setEASOnlyAdmin() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setEAS(address(0x1));
    }

    function test_setEASRejectsAddressWithoutCode() public {
        ReputationStorage freshImpl = new ReputationStorage();
        ReputationStorage fresh = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(identity), address(router), admin))
                )
            )
        );
        vm.prank(admin);
        vm.expectRevert("eas has no code");
        fresh.setEAS(makeAddr("eoaEas"));
    }

    function test_easAndSchemasCannotChangeAfterPayment() public {
        vm.startPrank(admin);
        vm.expectRevert("records exist");
        reputation.setEAS(address(0x1));
        vm.expectRevert("records exist");
        reputation.setOutcomeSchema(bytes32(uint256(123)));
        vm.expectRevert("records exist");
        reputation.setConfirmationSchema(bytes32(uint256(456)));
        vm.stopPrank();
    }

    function test_setSchemaOnlyAdmin() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setOutcomeSchema(bytes32(uint256(1)));
        vm.prank(buyer);
        vm.expectRevert("not admin");
        reputation.setConfirmationSchema(bytes32(uint256(1)));
    }

    // ── Per-service stats view ──────────────────────────────────────────

    function test_getServiceStats() public {
        // No outcome yet → all zeros.
        (
            uint256 completed,
            uint256 failed,
            uint256 canceled,
            uint256 confirmed,
            uint256 notConfirmed_,
            uint256 ref_,
            uint256 transactions
        ) = reputation.getServiceStats(serviceId);
        assertEq(completed + failed + canceled + confirmed + notConfirmed_ + ref_, 0);
        assertEq(transactions, 1);

        vm.prank(provider);
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        vm.prank(provider);
        usdc.approve(address(router), 15e6);
        vm.prank(provider);
        router.refund(paymentId, 15e6);

        (completed, failed, canceled, confirmed, notConfirmed_, ref_, transactions) =
            reputation.getServiceStats(serviceId);
        assertEq(completed, 1);
        assertEq(failed, 0);
        assertEq(canceled, 0);
        assertEq(confirmed, 1);
        assertEq(notConfirmed_, 0);
        assertEq(ref_, 15e6);
        assertEq(transactions, 1);
    }
}
