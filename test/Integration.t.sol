// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {DaskiValidationRegistry} from "../src/DaskiValidationRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {AttestationRequest, AttestationRequestData} from "../src/interfaces/IEAS.sol";

/// @notice End-to-end: agents register on the (mocked) canonical ERC-8004
///         IdentityRegistry, a Daski provider lists, services are registered
///         in ServiceRegistry, x402 payment settles through the
///         ServiceRegistry-validated route, provider attests outcome, buyer
///         confirms via EAS, refund mirrors per-service into
///         ReputationStorage, and a final test verifies per-service vs.
///         per-provider counters. Public ERC-8004 feedback lives in the
///         canonical ReputationRegistry singleton (gateway-written,
///         off-chain concern) and is not exercised here.
contract IntegrationTest is Test {
    MockUSDC usdc;
    MockEAS eas;
    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    DaskiValidationRegistry validationRegistry;
    ProviderRegistry registry;
    ServiceRegistry services;
    PaymentRouter router;
    X402Adapter adapter;
    ReputationStorage reputation;
    MockSanctionsList sanctions;

    bytes32 outcomeSchemaUid;
    bytes32 confirmationSchemaUid;

    address admin = address(this);
    address treasury = makeAddr("treasury");
    uint256 constant BUYER_KEY = 0xB0B;
    address buyer;
    address provider = makeAddr("provider");
    address unauthorized = makeAddr("unauthorized");
    address relayer = makeAddr("relayer");

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

        DaskiValidationRegistry valRegImpl = new DaskiValidationRegistry();
        validationRegistry = DaskiValidationRegistry(
            address(
                new ERC1967Proxy(
                    address(valRegImpl),
                    abi.encodeCall(DaskiValidationRegistry.initialize, (address(identity), address(sanctions), admin))
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

        ReputationStorage repStoreImpl = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(repStoreImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), admin))
                )
            )
        );

        outcomeSchemaUid = eas.register("uint256 paymentId,uint8 outcome", address(reputation), false);
        confirmationSchemaUid = eas.register("uint256 paymentId,uint8 confirmation", address(reputation), true);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchemaUid);
        reputation.setConfirmationSchema(confirmationSchemaUid);
        reputation.finalizeConfiguration();

        router.setReputationStorage(address(reputation));
        router.setAdapter(address(adapter), true);
        adapter.setFacilitatorAuthorization(relayer, true);
        router.setAcceptedToken(address(usdc), true);
        router.setTokenReputationConfig(address(usdc), true, 250_000);
    }

    function _signedAuthAndSettle(
        uint256 buyerKey,
        address buyerAddr,
        uint256 amount,
        bytes32 ref,
        uint256 providerAgentId,
        bytes32 svcId
    ) internal returns (uint256 paymentId) {
        bytes32 nonceSalt = keccak256(abi.encode("integration-x402-v2", ref));
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = adapter.authNonceFor(
            address(usdc), buyerAddr, amount, 0, validBefore, ref, providerAgentId, svcId, nonceSalt
        );
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm, buyerKey, address(usdc), buyerAddr, address(adapter), amount, 0, validBefore, nonce
        );
        vm.prank(relayer);
        paymentId = adapter.settle(address(usdc), amount, ref, providerAgentId, svcId, auth, nonceSalt);
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

    function _confirmReq(uint256 pid) internal view returns (AttestationRequest memory) {
        return AttestationRequest({
            schema: confirmationSchemaUid,
            data: AttestationRequestData({
                recipient: _providerRecipient(pid),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(pid, uint8(ReputationStorageBase.BuyerConfirmation.Confirmed)),
                value: 0
            })
        });
    }

    function _providerRecipient(uint256 pid) internal view returns (address) {
        pid;
        return provider;
    }

    function test_fullProtocolFlow() public {
        usdc.mint(buyer, 1000e6);

        // 1. Buyer registers as ERC-8004 agent on the canonical registry and
        //    binds itself in the Daski AgentIndex (payment attribution).
        vm.prank(buyer);
        uint256 buyerAgentId = identity.register("ipfs://buyer-agent");
        assertEq(buyerAgentId, 0);
        vm.prank(buyer);
        agentIndex.claim(buyerAgentId);

        // 2. Provider registers as ERC-8004 agent (one NFT, one operator)
        //    and verifies its payment wallet.
        vm.prank(provider);
        uint256 providerAgentId = identity.register("https://provider.example/agent.json");
        assertEq(providerAgentId, 1);
        identity.forceSetAgentWallet(providerAgentId, provider);

        // 3. Provider lists with Daski
        usdc.mint(provider, 1e6);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1e6);
        registry.register(providerAgentId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 1e6);

        // 3a. Provider registers a service in ServiceRegistry. Reputation
        //     queries downstream key off this serviceId.
        vm.prank(provider);
        bytes32 serviceId =
            services.registerService(providerAgentId, "domain-registration", "1", "ipfs://service", address(0));

        // 4. Buyer signs EIP-3009 (to=router); relayer settles via X402Adapter.
        bytes32 serviceRef = keccak256("service-1");
        uint256 paymentId = _signedAuthAndSettle(BUYER_KEY, buyer, 100e6, serviceRef, providerAgentId, serviceId);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6);

        IPaymentRouter.PaymentRecord memory record = router.getPayment(paymentId);
        assertEq(record.buyerAgentId, 0);
        assertEq(record.providerAgentId, 1);
        assertEq(record.serviceId, serviceId);
        assertEq(record.amount, 100e6);
        assertEq(record.token, address(usdc));
        assertEq(record.cachedBuyerWallet, buyer);
        assertEq(record.paidAt, block.timestamp, "paidAt captures settlement timestamp");

        // 5. Provider attests outcome via EAS.
        AttestationRequest memory outcomeReq =
            _outcomeReq(paymentId, ReputationStorageBase.TransactionOutcome.Completed);

        vm.prank(unauthorized);
        vm.expectRevert("not provider for this payment");
        eas.attest(outcomeReq);

        vm.prank(provider);
        eas.attest(outcomeReq);

        // 6. Buyer submits confirmation via EAS.
        vm.prank(buyer);
        eas.attest(_confirmReq(paymentId));

        // 7. Provider refunds a goodwill amount; reputation mirrors it per-service.
        vm.prank(provider);
        usdc.approve(address(router), 10e6);
        vm.prank(provider);
        router.refund(paymentId, 10e6);

        assertEq(router.refundedAmount(paymentId), 10e6);
        assertEq(reputation.refundedAmount(paymentId), 10e6);
        assertEq(reputation.refundedAmountByService(serviceId), 10e6);
        assertEq(usdc.balanceOf(buyer), 910e6);

        // 8. Public ERC-8004 feedback lives in the CANONICAL
        //    ReputationRegistry singleton (0x8004B... on Base / Base
        //    Sepolia), written by the gateway per confirmed delivery — an
        //    off-chain integration, not part of this contract suite.

        // 9. DaskiValidationRegistry (ERC-8004-inspired; the canonical
        //    validation registry does not exist yet)
        address validator = makeAddr("validator");
        bytes32 reqHash = keccak256("validation-req-1");
        vm.prank(provider);
        bytes32 validationKey = validationRegistry.validationRequest(validator, providerAgentId, "ipfs://req", reqHash);
        vm.prank(validator);
        validationRegistry.validationResponse(validationKey, 100, "ipfs://resp", keccak256("resp"), "pass");

        (, uint256 validatedAgentId, uint8 response,,,) = validationRegistry.getValidationStatus(validationKey);
        assertEq(validatedAgentId, providerAgentId);
        assertEq(response, 100);

        // 10. Final stats — per-provider AND per-service.
        (uint256 completedP,,, uint256 confirmedP,,) = reputation.getProviderStats(providerAgentId);
        assertEq(completedP, 1);
        assertEq(confirmedP, 1);

        (uint256 completedS,,, uint256 confirmedS,, uint256 refundedS,) = reputation.getServiceStats(serviceId);
        assertEq(completedS, 1);
        assertEq(confirmedS, 1);
        assertEq(refundedS, 10e6);
    }

    /// @notice Section 11.5 of the brief: one provider, two services. Run
    ///         multiple payments, confirm all, refund only on service A.
    ///         Verify per-service split and per-provider blend.
    function test_oneProviderTwoServices_perServiceVsPerProviderStats() public {
        // Buyer + provider setup
        vm.prank(buyer);
        uint256 buyerAgentId = identity.register("ipfs://buyer");
        vm.prank(buyer);
        agentIndex.claim(buyerAgentId);
        usdc.mint(buyer, 1000e6);

        vm.prank(provider);
        uint256 providerAgentId = identity.register("ipfs://provider");
        identity.forceSetAgentWallet(providerAgentId, provider);
        usdc.mint(provider, 1e6);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1e6);
        registry.register(providerAgentId);
        vm.stopPrank();

        vm.prank(provider);
        bytes32 svcA = services.registerService(providerAgentId, "service-A", "1", "u", address(0));
        vm.prank(provider);
        bytes32 svcB = services.registerService(providerAgentId, "service-B", "1", "u", address(0));

        // 3 payments to A, 2 payments to B
        uint256[] memory aPayments = new uint256[](3);
        uint256[] memory bPayments = new uint256[](2);
        for (uint256 i = 0; i < 3; i++) {
            aPayments[i] =
                _signedAuthAndSettle(BUYER_KEY, buyer, 50e6, keccak256(abi.encode("a", i)), providerAgentId, svcA);
        }
        for (uint256 i = 0; i < 2; i++) {
            bPayments[i] =
                _signedAuthAndSettle(BUYER_KEY, buyer, 50e6, keccak256(abi.encode("b", i)), providerAgentId, svcB);
        }

        // Provider attests Completed for each, buyer confirms each.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(provider);
            eas.attest(_outcomeReq(aPayments[i], ReputationStorageBase.TransactionOutcome.Completed));
            vm.prank(buyer);
            eas.attest(_confirmReq(aPayments[i]));
        }
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(provider);
            eas.attest(_outcomeReq(bPayments[i], ReputationStorageBase.TransactionOutcome.Completed));
            vm.prank(buyer);
            eas.attest(_confirmReq(bPayments[i]));
        }

        // Refund 5 USDC against the FIRST service-A payment only.
        vm.prank(provider);
        usdc.approve(address(router), 5e6);
        vm.prank(provider);
        router.refund(aPayments[0], 5e6);

        // Per-service: A has 3 confirmed/completed, B has 2.
        (uint256 cA,,, uint256 confA,, uint256 refA,) = reputation.getServiceStats(svcA);
        (uint256 cB,,, uint256 confB,, uint256 refB,) = reputation.getServiceStats(svcB);
        assertEq(cA, 3);
        assertEq(confA, 3);
        assertEq(refA, 5e6);
        assertEq(cB, 2);
        assertEq(confB, 2);
        assertEq(refB, 0, "service B refunds untouched");

        // Per-provider: 5 confirmed/completed total, blended.
        (uint256 cP,,, uint256 confP,,) = reputation.getProviderStats(providerAgentId);
        assertEq(cP, 5);
        assertEq(confP, 5);
    }

    /// @notice Three-layer cardinality regression. One provider, ONE
    ///         service (`serviceSlug = "domain-registration"`). The
    ///         off-chain serviceURI JSON declares two skills
    ///         (`register-domain`, `renew-domain`) that implement the
    ///         service. Three settlements occur — two intended to invoke
    ///         `register-domain` and one to invoke `renew-domain`. The
    ///         on-chain payment binding is identical for all three
    ///         (same serviceId) because skills are off-chain plumbing,
    ///         not on-chain identity.
    ///
    /// Pins the intended cardinality: services are product categories,
    /// skills are A2A methods, and multiple skills can roll up into one
    /// service. Pre-fix, an implementer might have registered one
    /// Service per skill — this test would still PASS in that scenario
    /// (nothing forbids it), but the assertions below are written
    /// against the *correct* model and provider implementations should
    /// follow it.
    function test_threeLayerCardinality_skillsRollUpToOneService() public {
        vm.prank(buyer);
        uint256 buyerAgentId = identity.register("ipfs://buyer");
        vm.prank(buyer);
        agentIndex.claim(buyerAgentId);
        usdc.mint(buyer, 1000e6);

        vm.prank(provider);
        uint256 providerAgentId = identity.register("ipfs://provider");
        identity.forceSetAgentWallet(providerAgentId, provider);
        usdc.mint(provider, 1e6);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1e6);
        registry.register(providerAgentId);
        vm.stopPrank();

        // ONE on-chain service. The skills (register-domain, renew-domain)
        // live in the off-chain JSON pointed to by serviceURI; on-chain we
        // only know about the slug.
        vm.prank(provider);
        bytes32 serviceId = services.registerService(
            providerAgentId, "domain-registration", "1", "ipfs://domain-registration-service.json", address(0)
        );

        // Three settlements — two notionally invoking `register-domain`,
        // one `renew-domain`. The skill name never appears on-chain; the
        // only on-chain identity is the shared serviceId.
        uint256 pid1 =
            _signedAuthAndSettle(BUYER_KEY, buyer, 15e6, keccak256("svc-A-register-1"), providerAgentId, serviceId);
        uint256 pid2 =
            _signedAuthAndSettle(BUYER_KEY, buyer, 15e6, keccak256("svc-A-register-2"), providerAgentId, serviceId);
        uint256 pid3 =
            _signedAuthAndSettle(BUYER_KEY, buyer, 10e6, keccak256("svc-A-renew-1"), providerAgentId, serviceId);

        // All three payment records carry the SAME serviceId. The router
        // does not care which skill the buyer is invoking — that's a
        // gateway/provider concern.
        assertEq(router.getPayment(pid1).serviceId, serviceId);
        assertEq(router.getPayment(pid2).serviceId, serviceId);
        assertEq(router.getPayment(pid3).serviceId, serviceId);

        // Provider attests outcomes, buyer confirms all three.
        vm.prank(provider);
        eas.attest(_outcomeReq(pid1, ReputationStorageBase.TransactionOutcome.Completed));
        vm.prank(provider);
        eas.attest(_outcomeReq(pid2, ReputationStorageBase.TransactionOutcome.Completed));
        vm.prank(provider);
        eas.attest(_outcomeReq(pid3, ReputationStorageBase.TransactionOutcome.Completed));
        vm.prank(buyer);
        eas.attest(_confirmReq(pid1));
        vm.prank(buyer);
        eas.attest(_confirmReq(pid2));
        vm.prank(buyer);
        eas.attest(_confirmReq(pid3));

        // Reputation rolls up at the service level: 3 completed,
        // 3 confirmed against the SAME serviceId. Provider-level numbers
        // match because there's only one service.
        (uint256 svcCompleted,,, uint256 svcConfirmed,,,) = reputation.getServiceStats(serviceId);
        assertEq(svcCompleted, 3, "all three skill invocations roll up to one service");
        assertEq(svcConfirmed, 3);

        (uint256 provCompleted,,, uint256 provConfirmed,,) = reputation.getProviderStats(providerAgentId);
        assertEq(provCompleted, 3);
        assertEq(provConfirmed, 3);

        // Per-provider service count is ONE — not three (would-be wrong
        // cardinality from pre-fix per-skill registration).
        assertEq(services.getServiceCountByProvider(providerAgentId), 1);
    }
}
