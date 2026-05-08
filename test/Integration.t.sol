// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
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
    Signature
} from "../src/interfaces/IEAS.sol";

/// @notice End-to-end: an ERC-8004 agent registers, a Daski provider lists,
///         x402 payment settles VIA X402Adapter, provider attests outcome
///         via EAS, buyer attests confirmation via delegated EAS, refund
///         mirrors into ReputationStorage, and the ERC-8004
///         ReputationRegistry / ValidationRegistry accept independent
///         feedback on the same agent.
contract IntegrationTest is Test {
    MockUSDC usdc;
    MockEAS eas;
    IdentityRegistry identity;
    ReputationRegistry reputationRegistry;
    ValidationRegistry validationRegistry;
    ProviderRegistry registry;
    PaymentRouter router;
    X402Adapter adapter;
    ReputationStorage reputation;

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

        IdentityRegistry idImpl = new IdentityRegistry();
        identity = IdentityRegistry(
            address(new ERC1967Proxy(address(idImpl), abi.encodeCall(IdentityRegistry.initialize, (admin))))
        );

        ReputationRegistry repRegImpl = new ReputationRegistry();
        reputationRegistry = ReputationRegistry(
            address(
                new ERC1967Proxy(
                    address(repRegImpl), abi.encodeCall(ReputationRegistry.initialize, (address(identity), admin))
                )
            )
        );

        ValidationRegistry valRegImpl = new ValidationRegistry();
        validationRegistry = ValidationRegistry(
            address(
                new ERC1967Proxy(
                    address(valRegImpl), abi.encodeCall(ValidationRegistry.initialize, (address(identity), admin))
                )
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

        router.setAdapter(address(adapter), true);
        router.setAcceptedToken(address(usdc), true);

        ReputationStorage repStoreImpl = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(repStoreImpl),
                    abi.encodeCall(ReputationStorage.initialize, (address(identity), address(router), admin))
                )
            )
        );

        outcomeSchemaUid =
            eas.register("uint256 paymentId,uint8 outcome,uint256 fulfillmentTime", address(reputation), false);
        confirmationSchemaUid = eas.register("uint256 paymentId,uint8 confirmation", address(reputation), true);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchemaUid);
        reputation.setConfirmationSchema(confirmationSchemaUid);

        router.setReputationStorage(address(reputation));
    }

    function test_fullProtocolFlow() public {
        usdc.mint(buyer, 1000e6);

        // 1. Buyer registers as ERC-8004 agent
        vm.prank(buyer);
        uint256 buyerAgentId = identity.register("ipfs://buyer-agent");
        assertEq(buyerAgentId, 1);

        // 2. Provider registers as ERC-8004 agent
        vm.prank(provider);
        uint256 providerAgentId = identity.register("https://provider.example/agent.json");
        assertEq(providerAgentId, 2);

        // 3. Provider lists with Daski (pays 1 USDC listing fee)
        usdc.mint(provider, 1e6);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1e6);
        registry.register(providerAgentId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 1e6);

        // 4. Buyer signs EIP-3009 (to=router); relayer settles via X402Adapter.
        //    Nonce binds the auth to (serviceRef, providerAgentId) — without
        //    this binding a frontrunner could redirect the payment.
        bytes32 serviceRef = keccak256("service-1");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm,
            BUYER_KEY,
            address(usdc),
            buyer,
            address(router),
            100e6,
            0,
            block.timestamp + 1 hours,
            keccak256(abi.encode(serviceRef, providerAgentId))
        );
        vm.prank(relayer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, serviceRef, providerAgentId, auth);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6);

        IPaymentRouter.PaymentRecord memory record = router.getPayment(paymentId);
        assertEq(record.buyerAgentId, 1);
        assertEq(record.providerAgentId, 2);
        assertEq(record.amount, 100e6);
        assertEq(record.token, address(usdc));
        assertEq(record.cachedBuyerWallet, buyer);
        assertEq(record.paidAt, block.timestamp, "paidAt captures settlement timestamp");

        // 5. Provider attests outcome via EAS (direct call; providers hold
        //    their own wallet and pay gas).
        AttestationRequest memory outcomeReq = AttestationRequest({
            schema: outcomeSchemaUid,
            data: AttestationRequestData({
                recipient: address(0),
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: abi.encode(paymentId, uint8(ReputationStorage.TransactionOutcome.Completed), uint256(3600)),
                value: 0
            })
        });

        vm.prank(unauthorized);
        vm.expectRevert("no identity");
        eas.attest(outcomeReq);

        vm.prank(provider);
        eas.attest(outcomeReq);

        // 6. Buyer submits confirmation via delegated attestation; relayer
        //    (gateway) pays gas. Mock EAS skips sig verification, but the
        //    resolver still enforces attester == buyer agent.
        DelegatedAttestationRequest memory confirmReq = DelegatedAttestationRequest({
            schema: confirmationSchemaUid,
            data: AttestationRequestData({
                recipient: address(0),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(paymentId, uint8(ReputationStorage.BuyerConfirmation.Confirmed)),
                value: 0
            }),
            signature: Signature({v: 0, r: bytes32(0), s: bytes32(0)}),
            attester: buyer,
            deadline: type(uint64).max
        });

        vm.prank(relayer);
        eas.attestByDelegation(confirmReq);

        // 7. Provider refunds a goodwill amount; reputation mirrors it.
        vm.prank(provider);
        usdc.approve(address(router), 10e6);
        vm.prank(provider);
        router.refund(paymentId, 10e6);

        assertEq(router.refundedAmount(paymentId), 10e6);
        assertEq(reputation.refundedAmount(paymentId), 10e6);
        assertEq(usdc.balanceOf(buyer), 910e6);

        // 8. ERC-8004 ReputationRegistry: external reviewer leaves feedback.
        address reviewer = makeAddr("reviewer");
        vm.prank(reviewer);
        reputationRegistry.giveFeedback(
            providerAgentId, 90, 0, "starred", "", "https://provider.example", "", bytes32(0)
        );
        assertEq(reputationRegistry.getLastIndex(providerAgentId, reviewer), 1);

        // 9. ERC-8004 ValidationRegistry: provider requests validation of a job.
        address validator = makeAddr("validator");
        bytes32 reqHash = keccak256("validation-req-1");
        vm.prank(provider);
        validationRegistry.validationRequest(validator, providerAgentId, "ipfs://req", reqHash);
        vm.prank(validator);
        validationRegistry.validationResponse(reqHash, 100, "ipfs://resp", keccak256("resp"), "pass");

        (, uint256 validatedAgentId, uint8 response,,,) = validationRegistry.getValidationStatus(reqHash);
        assertEq(validatedAgentId, providerAgentId);
        assertEq(response, 100);

        // 10. Final check: Daski aggregate stats from the resolver.
        (uint256 completed,,, uint256 confirmed,) = reputation.getProviderStats(providerAgentId);
        assertEq(completed, 1);
        assertEq(confirmed, 1);
    }
}
