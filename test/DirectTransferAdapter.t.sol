// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {DirectTransferAdapter} from "../src/adapters/DirectTransferAdapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";

/// @dev Exercises the external-facilitator rail: an EIP-3009 authorization
///      with a CLIENT-CHOSEN (random) nonce is submitted as a bare
///      `transferWithAuthorization` by an external facilitator (CDP stand-in),
///      then the gateway attributor calls `attribute` to run the router split
///      and bookkeeping for funds that already sit on the router.
contract DirectTransferAdapterTest is Test {
    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    ProviderRegistry registry;
    ServiceRegistry services;
    PaymentRouter router;
    DirectTransferAdapter adapter;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address attributor = makeAddr("attributor");
    // Stand-in for the CDP facilitator: any address may submit a bare
    // transferWithAuthorization — the token only checks the signature.
    address externalFacilitator = makeAddr("externalFacilitator");
    address provider = makeAddr("provider");

    uint256 constant BUYER_KEY = 0xA11CE;
    address buyer;
    uint256 buyerAgentId;
    uint256 providerAgentId;
    bytes32 serviceId;

    event DirectTransferAttributed(
        uint256 indexed paymentId, bytes32 indexed serviceRef, address indexed from, bytes32 authNonce
    );

    function setUp() public {
        buyer = vm.addr(BUYER_KEY);
        usdc = new MockUSDC();

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

        DirectTransferAdapter aImpl = new DirectTransferAdapter();
        adapter = DirectTransferAdapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(DirectTransferAdapter.initialize, (address(router), address(agentIndex), admin))
                )
            )
        );

        vm.startPrank(admin);
        router.setAdapter(address(adapter), true);
        router.setAcceptedToken(address(usdc), true);
        adapter.setAttributor(attributor, true);
        vm.stopPrank();

        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example.com/agent.json");
        // Canonical registries never auto-set agentWallet; payee resolution
        // needs one (or a serviceWallet).
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
        // The attributor resolves the buyer through the AgentIndex — bind it.
        vm.prank(buyer);
        agentIndex.claim(buyerAgentId);
        usdc.mint(buyer, 1000e6);
    }

    /// @dev Sign an EIP-3009 auth with a random (client-chosen) nonce and
    ///      submit it as a bare transferWithAuthorization from the external
    ///      facilitator — the exact shape of a CDP `exact`-scheme settle.
    function _externalSettle(uint256 value, bytes32 nonce) internal {
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(usdc), buyer, address(router), value, 0, block.timestamp + 1 hours, nonce
        );
        vm.prank(externalFacilitator);
        usdc.transferWithAuthorization(
            buyer, address(router), value, auth.validAfter, auth.validBefore, auth.nonce, auth.v, auth.r, auth.s
        );
    }

    function test_attributeHappyPath() public {
        bytes32 nonce = keccak256("client-random-nonce-1");
        bytes32 ref = keccak256("ref-1");
        _externalSettle(100e6, nonce);

        // Funds sit on the router, unsplit, until attribution.
        assertEq(usdc.balanceOf(address(router)), 100e6);

        vm.expectEmit(false, true, true, true, address(adapter));
        emit DirectTransferAttributed(0, ref, buyer, nonce);
        vm.prank(attributor);
        uint256 paymentId = adapter.attribute(address(usdc), 100e6, ref, providerAgentId, serviceId, buyer, nonce);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6); // 5e6 commission + 1e6 listing fee from setUp
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertTrue(router.serviceRefUsed(ref));

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(rec.providerAgentId, providerAgentId);
        assertEq(rec.serviceId, serviceId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.token, address(usdc));
    }

    function test_attributeNotAttributorReverts() public {
        bytes32 nonce = keccak256("nonce-na");
        _externalSettle(100e6, nonce);

        vm.prank(makeAddr("rando"));
        vm.expectRevert("not attributor");
        adapter.attribute(address(usdc), 100e6, keccak256("ref-na"), providerAgentId, serviceId, buyer, nonce);
    }

    function test_attributeAuthNotConsumedReverts() public {
        // No external settle happened — authorizationState is false, so a
        // buggy attributor cannot invent a payment out of thin air.
        vm.prank(attributor);
        vm.expectRevert("authorization not consumed");
        adapter.attribute(
            address(usdc), 100e6, keccak256("ref-nc"), providerAgentId, serviceId, buyer, keccak256("never-used")
        );
    }

    function test_attributeUnderFundedReverts() public {
        // Authorization consumed for 50e6, but attribution claims 100e6.
        // The router's balance check catches the over-claim.
        bytes32 nonce = keccak256("nonce-uf");
        _externalSettle(50e6, nonce);

        vm.prank(attributor);
        vm.expectRevert("router under-funded");
        adapter.attribute(address(usdc), 100e6, keccak256("ref-uf"), providerAgentId, serviceId, buyer, nonce);
    }

    function test_attributeServiceRefReplayReverts() public {
        bytes32 ref = keccak256("ref-replay");
        bytes32 nonce1 = keccak256("nonce-r1");
        bytes32 nonce2 = keccak256("nonce-r2");
        _externalSettle(50e6, nonce1);
        _externalSettle(50e6, nonce2);

        vm.prank(attributor);
        adapter.attribute(address(usdc), 50e6, ref, providerAgentId, serviceId, buyer, nonce1);

        // Second attribution against the SAME serviceRef must fail even
        // though a second consumed authorization exists — idempotency for
        // gateway retries lives on serviceRef, not the auth nonce.
        vm.prank(attributor);
        vm.expectRevert("serviceRef used");
        adapter.attribute(address(usdc), 50e6, ref, providerAgentId, serviceId, buyer, nonce2);
    }

    function test_attributeBuyerNoAgentReverts() public {
        // A fresh wallet without an ERC-8004 identity can move USDC to the
        // router (the token doesn't care), but attribution must reject it —
        // there is no atomic-register path on the external rail.
        uint256 freshKey = 0xF4E5;
        address fresh = vm.addr(freshKey);
        usdc.mint(fresh, 100e6);
        bytes32 nonce = keccak256("nonce-fresh");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, freshKey, address(usdc), fresh, address(router), 100e6, 0, block.timestamp + 1 hours, nonce
        );
        vm.prank(externalFacilitator);
        usdc.transferWithAuthorization(
            fresh, address(router), 100e6, auth.validAfter, auth.validBefore, auth.nonce, auth.v, auth.r, auth.s
        );

        vm.prank(attributor);
        vm.expectRevert("buyer has no agent");
        adapter.attribute(address(usdc), 100e6, keccak256("ref-fresh"), providerAgentId, serviceId, fresh, nonce);
    }

    function test_attributeUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        vm.prank(attributor);
        vm.expectRevert("token not accepted");
        adapter.attribute(
            address(other), 100e6, keccak256("ref-tok"), providerAgentId, serviceId, buyer, keccak256("n")
        );
    }

    function test_attributeTwoPendingTransfersOrderIndependent() public {
        // Two external settles land before either attribution — each
        // attribution consumes exactly its own amount from the pooled
        // router balance.
        bytes32 nonceA = keccak256("nonce-A");
        bytes32 nonceB = keccak256("nonce-B");
        _externalSettle(30e6, nonceA);
        _externalSettle(70e6, nonceB);
        assertEq(usdc.balanceOf(address(router)), 100e6);

        vm.prank(attributor);
        adapter.attribute(address(usdc), 70e6, keccak256("ref-B"), providerAgentId, serviceId, buyer, nonceB);
        vm.prank(attributor);
        adapter.attribute(address(usdc), 30e6, keccak256("ref-A"), providerAgentId, serviceId, buyer, nonceA);

        assertEq(usdc.balanceOf(address(router)), 0);
        // 100e6 total: 5% commission → 95e6 to provider, 5e6 + 1e6 listing
        // fee to treasury.
        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6);
    }

    function test_setAttributorAdminOnly() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert("not admin");
        adapter.setAttributor(makeAddr("x"), true);

        vm.prank(admin);
        vm.expectRevert("zero attributor");
        adapter.setAttributor(address(0), true);

        vm.prank(admin);
        adapter.setAttributor(makeAddr("x"), true);
        assertTrue(adapter.attributors(makeAddr("x")));

        vm.prank(admin);
        adapter.setAttributor(makeAddr("x"), false);
        assertFalse(adapter.attributors(makeAddr("x")));
    }

    function test_attributeRevokedAttributorReverts() public {
        bytes32 nonce = keccak256("nonce-revoked");
        _externalSettle(100e6, nonce);

        vm.prank(admin);
        adapter.setAttributor(attributor, false);

        vm.prank(attributor);
        vm.expectRevert("not attributor");
        adapter.attribute(address(usdc), 100e6, keccak256("ref-rv"), providerAgentId, serviceId, buyer, nonce);
    }
}
