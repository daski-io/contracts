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
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";

contract ReputationStorageTest is Test {
    uint256 constant REPUTATION_MINIMUM = 250_000;

    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    ProviderRegistry registry;
    ServiceRegistry services;
    PaymentRouter router;
    X402Adapter adapter;
    ReputationStorage reputation;
    MockUSDC usdc;
    MockEAS eas;
    MockSanctionsList sanctions;

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
        sanctions = new MockSanctionsList();

        identity = new MockCanonicalIdentityRegistry();
        AgentIndex aiImpl = new AgentIndex();
        agentIndex = AgentIndex(
            address(
                new ERC1967Proxy(
                    address(aiImpl),
                    abi.encodeCall(AgentIndex.initialize, (address(identity), address(sanctions), admin))
                )
            )
        );

        ProviderRegistry regImpl = new ProviderRegistry();
        registry = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(
                        ProviderRegistry.initialize,
                        (address(identity), address(usdc), treasury, 1_000_000, address(sanctions), admin)
                    )
                )
            )
        );

        ServiceRegistry sregImpl = new ServiceRegistry();
        services = ServiceRegistry(
            address(
                new ERC1967Proxy(
                    address(sregImpl),
                    abi.encodeCall(
                        ServiceRegistry.initialize, (address(identity), address(registry), address(sanctions), admin)
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
                        PaymentRouter.initialize,
                        (
                            address(identity),
                            address(registry),
                            address(services),
                            treasury,
                            500,
                            address(sanctions),
                            admin
                        )
                    )
                )
            )
        );

        X402Adapter aImpl = new X402Adapter();
        adapter = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(
                        X402Adapter.initialize, (address(router), address(agentIndex), address(sanctions), admin)
                    )
                )
            )
        );

        ReputationStorage repImpl = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(repImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), admin))
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
        reputation.finalizeConfiguration();
        router.setReputationStorage(address(reputation));
        router.setAdapter(address(adapter), true);
        adapter.setFacilitatorAuthorization(relayer, true);
        router.setAcceptedToken(address(usdc), true);
        router.setTokenReputationConfig(address(usdc), true, REPUTATION_MINIMUM);
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

    function _payAsBuyer(uint256 amount, bytes32 serviceRef, bytes32 svcId) internal returns (uint256) {
        bytes32 nonceSalt = keccak256(abi.encode("reputation-x402-v2", serviceRef));
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = adapter.authNonceFor(
            address(usdc), buyer, amount, 0, validBefore, serviceRef, providerAgentId, svcId, nonceSalt
        );
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            amount,
            0,
            validBefore,
            nonce
        );
        vm.prank(relayer);
        return adapter.settle(address(usdc), amount, serviceRef, providerAgentId, svcId, auth, nonceSalt);
    }

    function _createSecondPayment() internal returns (uint256 paymentId2, uint256 provider2AgentId, address buyer2) {
        address provider2 = makeAddr("provider2");
        bytes32 secondServiceId;
        (provider2AgentId, secondServiceId) = _registerSecondProvider(provider2);

        uint256 secondBuyerKey = 0xDEAD;
        buyer2 = vm.addr(secondBuyerKey);
        vm.prank(buyer2);
        uint256 buyer2AgentId = identity.register();
        vm.prank(buyer2);
        agentIndex.claim(buyer2AgentId);
        usdc.mint(buyer2, 100e6);

        paymentId2 = _settleSecondPayment(secondBuyerKey, buyer2, provider2AgentId, secondServiceId);
        providerRecipients[paymentId2] = provider2;
    }

    function _registerSecondProvider(address provider2)
        internal
        returns (uint256 provider2AgentId, bytes32 secondServiceId)
    {
        vm.prank(provider2);
        provider2AgentId = identity.register("https://provider2.example/agent.json");
        identity.forceSetAgentWallet(provider2AgentId, provider2);
        usdc.mint(provider2, 1_000_000);
        vm.startPrank(provider2);
        usdc.approve(address(registry), 1_000_000);
        registry.register(provider2AgentId);
        vm.stopPrank();
        vm.prank(provider2);
        secondServiceId = services.registerService(provider2AgentId, "skill", "1", "u", address(0));
    }

    function _settleSecondPayment(
        uint256 secondBuyerKey,
        address buyer2,
        uint256 provider2AgentId,
        bytes32 secondServiceId
    ) internal returns (uint256) {
        bytes32 serviceRef = keccak256("attack-svc");
        bytes32 nonceSalt = keccak256(abi.encode("reputation-attacker-x402-v2", serviceRef));
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = adapter.authNonceFor(
            address(usdc), buyer2, 100e6, 0, validBefore, serviceRef, provider2AgentId, secondServiceId, nonceSalt
        );
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            secondBuyerKey,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer2,
            address(adapter),
            100e6,
            0,
            validBefore,
            nonce
        );
        vm.prank(relayer);
        return adapter.settle(address(usdc), 100e6, serviceRef, provider2AgentId, secondServiceId, auth, nonceSalt);
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

    function test_recordOutcomeSanctionedAttesterReverts() public {
        sanctions.setSanctioned(provider, true);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, provider));
        eas.attest(_outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed));

        assertFalse(reputation.getRecord(paymentId).outcomeRecorded);
    }

    function test_recordOutcomeSanctionedRecipientReverts() public {
        address providerWallet = makeAddr("sanctionedReputationRecipient");
        identity.forceSetAgentWallet(providerAgentId, providerWallet);
        usdc.mint(buyer, 100e6);
        uint256 secondPaymentId = _payAsBuyer(100e6, keccak256("sanctioned-recipient"), serviceId);
        providerRecipients[secondPaymentId] = providerWallet;
        sanctions.setSanctioned(providerWallet, true);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, providerWallet));
        eas.attest(_outcomeReq(secondPaymentId, ReputationStorageBase.TransactionOutcome.Completed));

        assertFalse(reputation.getRecord(secondPaymentId).outcomeRecorded);
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
        bytes32 uid = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorageBase.BuyerConfirmation.Confirmed));
        assertEq(rec.currentConfirmationUid, uid);
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

    function test_submitConfirmationMustBeRevocable() public {
        AttestationRequest memory request =
            _confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0));
        request.data.revocable = false;

        vm.prank(buyer);
        vm.expectRevert("confirmation must be revocable");
        eas.attest(request);
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
        bytes32 secondUid =
            eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.NotConfirmed, firstUid));

        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(reputation.confirmedByService(serviceId), 0);
        assertEq(reputation.notConfirmedCount(providerAgentId), 1);
        assertEq(reputation.notConfirmedByService(serviceId), 1);
        assertEq(reputation.buyerConfirmedCount(buyerAgentId), 0);
        assertEq(reputation.buyerNotConfirmedCount(buyerAgentId), 1);

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(paymentId);
        assertEq(uint256(rec.confirmation), uint256(ReputationStorageBase.BuyerConfirmation.NotConfirmed));
        assertEq(rec.currentConfirmationUid, secondUid);
    }

    function test_confirmationSecondWithoutRefUIDReverts() public {
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));

        vm.prank(buyer);
        vm.expectRevert("must ref current confirmation");
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
        vm.expectRevert("must ref current confirmation");
        eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, u1));
    }

    function test_confirmationRefUidFromOtherPayment_reverts() public {
        vm.prank(buyer);
        bytes32 victimUid =
            eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);

        (uint256 paymentId2, uint256 provider2AgentId, address buyer2) = _createSecondPayment();

        vm.prank(buyer2);
        vm.expectRevert("refUID is not a tracked confirmation");
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
        assertEq(rec.currentConfirmationUid, bytes32(0));
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

    function test_ineligiblePaymentIsRecordedButCannotAffectReputation() public {
        uint256 tinyAmount = REPUTATION_MINIMUM - 1;
        usdc.mint(buyer, tinyAmount);
        uint256 tinyPaymentId = _payAsBuyer(tinyAmount, keccak256("tiny-reputation"), serviceId);
        providerRecipients[tinyPaymentId] = provider;

        ReputationStorageBase.ReputationRecord memory rec = reputation.getRecord(tinyPaymentId);
        assertEq(rec.paymentId, tinyPaymentId);
        assertFalse(rec.reputationEligible);
        assertEq(reputation.providerTransactionCount(providerAgentId), 1);
        assertEq(reputation.serviceTransactionCount(serviceId), 1);
        assertEq(reputation.buyerTransactionCount(buyerAgentId), 1);

        vm.prank(provider);
        vm.expectRevert("payment not reputation eligible");
        eas.attest(_outcomeReq(tinyPaymentId, ReputationStorageBase.TransactionOutcome.Completed));

        vm.prank(buyer);
        vm.expectRevert("payment not reputation eligible");
        eas.attest(_confirmReq(tinyPaymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
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
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), admin))
                )
            )
        );
        vm.prank(admin);
        vm.expectRevert("eas has no code");
        fresh.setEAS(makeAddr("eoaEas"));
    }

    function test_configurationMustBeCompleteAndFinalizesOnce() public {
        ReputationStorage freshImpl = new ReputationStorage();
        ReputationStorage fresh = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), admin))
                )
            )
        );

        vm.prank(admin);
        vm.expectRevert("eas not configured");
        fresh.finalizeConfiguration();

        vm.prank(admin);
        fresh.setEAS(address(eas));
        vm.prank(admin);
        vm.expectRevert("outcome schema not configured");
        fresh.finalizeConfiguration();

        bytes32 freshOutcome = eas.register("uint256 paymentId,uint8 outcome", address(fresh), false);
        vm.prank(admin);
        fresh.setOutcomeSchema(freshOutcome);
        vm.prank(admin);
        vm.expectRevert("confirmation schema not configured");
        fresh.finalizeConfiguration();

        bytes32 freshConfirmation = eas.register("uint256 paymentId,uint8 confirmation", address(fresh), true);
        vm.prank(admin);
        fresh.setConfirmationSchema(freshConfirmation);
        vm.prank(admin);
        fresh.finalizeConfiguration();
        assertTrue(fresh.isConfigured());

        vm.prank(admin);
        vm.expectRevert("configuration finalized");
        fresh.finalizeConfiguration();
    }

    function test_easAndSchemasCannotChangeAfterPayment() public {
        assertTrue(reputation.isConfigured());
        vm.startPrank(admin);
        vm.expectRevert("configuration finalized");
        reputation.setEAS(address(0x1));
        vm.expectRevert("configuration finalized");
        reputation.setOutcomeSchema(bytes32(uint256(123)));
        vm.expectRevert("configuration finalized");
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

    // ── EAS batch entry points ──────────────────────────────────────────

    function _outcomeAttestation(uint256 pid, ReputationStorageBase.TransactionOutcome o, bytes32 uid)
        internal
        view
        returns (Attestation memory)
    {
        return Attestation({
            uid: uid,
            schema: outcomeSchemaUid,
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: 0,
            refUID: bytes32(0),
            recipient: _providerRecipient(pid),
            attester: provider,
            revocable: false,
            data: abi.encode(pid, uint8(o))
        });
    }

    function test_multiAttestProcessesEachEntry() public {
        usdc.mint(buyer, 60e6);
        uint256 paymentId2 = _payAsBuyer(60e6, keccak256("service-2"), serviceId);
        providerRecipients[paymentId2] = provider;

        Attestation[] memory batch = new Attestation[](2);
        batch[0] = _outcomeAttestation(paymentId, ReputationStorageBase.TransactionOutcome.Completed, keccak256("b1"));
        batch[1] = _outcomeAttestation(paymentId2, ReputationStorageBase.TransactionOutcome.Failed, keccak256("b2"));

        vm.prank(address(eas));
        assertTrue(reputation.multiAttest(batch, new uint256[](2)));

        assertTrue(reputation.getRecord(paymentId).outcomeRecorded);
        assertTrue(reputation.getRecord(paymentId2).outcomeRecorded);
        assertEq(reputation.completedCount(providerAgentId), 1);
        assertEq(reputation.failedCount(providerAgentId), 1);
    }

    function test_multiAttestSanctionedParticipantRevertsWholeBatch() public {
        usdc.mint(buyer, 60e6);
        uint256 paymentId2 = _payAsBuyer(60e6, keccak256("sanctioned-batch"), serviceId);
        providerRecipients[paymentId2] = provider;

        Attestation[] memory batch = new Attestation[](2);
        batch[0] = _outcomeAttestation(paymentId, ReputationStorageBase.TransactionOutcome.Completed, keccak256("b1"));
        batch[1] =
            _outcomeAttestation(paymentId2, ReputationStorageBase.TransactionOutcome.Failed, keccak256("sanctioned"));
        address sanctionedRecipient = makeAddr("sanctionedBatchRecipient");
        batch[1].recipient = sanctionedRecipient;
        sanctions.setSanctioned(sanctionedRecipient, true);

        vm.prank(address(eas));
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, sanctionedRecipient));
        reputation.multiAttest(batch, new uint256[](2));

        assertFalse(reputation.getRecord(paymentId).outcomeRecorded);
        assertFalse(reputation.getRecord(paymentId2).outcomeRecorded);
    }

    function test_multiAttestOnlyEAS() public {
        vm.prank(unauthorized);
        vm.expectRevert("not EAS");
        reputation.multiAttest(new Attestation[](0), new uint256[](0));
    }

    function test_multiRevokeProcessesEachEntry() public {
        vm.prank(buyer);
        bytes32 uid = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        assertEq(reputation.confirmedCount(providerAgentId), 1);

        Attestation[] memory batch = new Attestation[](1);
        batch[0] = eas.getAttestation(uid);

        vm.prank(address(eas));
        assertTrue(reputation.multiRevoke(batch, new uint256[](1)));

        assertEq(reputation.confirmedCount(providerAgentId), 0);
        assertEq(
            uint256(reputation.getRecord(paymentId).confirmation),
            uint256(ReputationStorageBase.BuyerConfirmation.Pending)
        );
    }

    function test_revokeSanctionedAttesterRevertsWithoutChangingReputation() public {
        vm.prank(buyer);
        bytes32 uid = eas.attest(_confirmReq(paymentId, ReputationStorageBase.BuyerConfirmation.Confirmed, bytes32(0)));
        sanctions.setSanctioned(buyer, true);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, buyer));
        eas.revoke(
            RevocationRequest({schema: confirmationSchemaUid, data: RevocationRequestData({uid: uid, value: 0})})
        );

        assertEq(
            uint256(reputation.getRecord(paymentId).confirmation),
            uint256(ReputationStorageBase.BuyerConfirmation.Confirmed)
        );
    }
}
