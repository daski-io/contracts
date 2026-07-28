// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {FeeOnTransferUSDC} from "./mocks/FeeOnTransferUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";
import {AgentIndexSigner} from "./helpers/AgentIndexSigner.sol";
import {MockReputationSink} from "./helpers/MockReputationSink.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract X402AdapterTest is Test {
    uint256 constant REPUTATION_MINIMUM = 250_000;

    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    ProviderRegistry registry;
    ServiceRegistry services;
    PaymentRouter router;
    X402Adapter adapter;
    MockUSDC usdc;
    MockSanctionsList sanctions;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address relayer = makeAddr("relayer");
    address provider = makeAddr("provider");

    uint256 constant BUYER_KEY = 0xA11CE;
    address buyer;
    uint256 buyerAgentId;
    uint256 providerAgentId;
    bytes32 serviceId;

    function setUp() public {
        buyer = vm.addr(BUYER_KEY);
        usdc = new MockUSDC();

        // Stand-in for the canonical ERC-8004 IdentityRegistry singleton,
        // plus the Daski AgentIndex the adapters resolve buyers through.
        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();
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

        MockReputationSink sink = new MockReputationSink(address(router));
        vm.prank(admin);
        router.setReputationStorage(address(sink));
        vm.prank(admin);
        router.setAdapter(address(adapter), true);
        vm.prank(admin);
        adapter.setFacilitatorAuthorization(relayer, true);
        vm.prank(admin);
        router.setAcceptedToken(address(usdc), true);
        vm.prank(admin);
        router.setTokenReputationConfig(address(usdc), true, REPUTATION_MINIMUM);

        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example.com/agent.json");
        // Keep the provider wallet explicit in this fixture.
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
        // Adapters resolve the buyer through the AgentIndex — bind it.
        vm.prank(buyer);
        agentIndex.claim(buyerAgentId);
        usdc.mint(buyer, 1000e6);
    }

    /// @dev Sign with an arbitrary nonce, matching standard x402 V2 clients.
    function _authFor(uint256 value, bytes32 serviceRef, uint256, bytes32)
        internal
        view
        returns (IX402Adapter.EIP3009Auth memory)
    {
        return EIP3009Signer.signTransfer(
            vm,
            BUYER_KEY,
            address(usdc),
            buyer,
            address(router),
            value,
            0,
            block.timestamp + 1 hours,
            keccak256(abi.encode("x402-v2-random-nonce", serviceRef))
        );
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

    function test_settleHappyPath() public {
        bytes32 ref = keccak256("ref-1");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        vm.prank(relayer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6); // includes 1 USDC listing fee from setUp
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(rec.providerAgentId, providerAgentId);
        assertEq(rec.serviceId, serviceId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.token, address(usdc));
    }

    function test_settleAcceptsNonceUnrelatedToDaskiRouting() public {
        bytes32 ref = keccak256("random-nonce-ref");
        bytes32 nonce = keccak256("official-client-random-nonce");
        assertNotEq(nonce, keccak256(abi.encode(ref, providerAgentId, serviceId)));
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(usdc), buyer, address(router), 100e6, 0, block.timestamp + 1 hours, nonce
        );

        vm.prank(relayer);
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);

        assertTrue(usdc.authorizationState(buyer, nonce));
    }

    function test_settleUnauthorizedCallerReverts() public {
        bytes32 ref = keccak256("unauthorized");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert("facilitator not authorized");
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);
    }

    function test_settleWithRegistrationUnauthorizedCallerReverts() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory regSig = _signRegisterAgent(FRESH_BUYER_KEY, freshBuyer, "ipfs://fresh", 0, deadline);
        bytes32 ref = keccak256("unauthorized-registration");
        IX402Adapter.EIP3009Auth memory auth =
            _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, ref, providerAgentId, serviceId);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert("facilitator not authorized");
        adapter.settleWithRegistration(
            address(usdc), 80e6, ref, providerAgentId, serviceId, auth, "ipfs://fresh", deadline, regSig
        );
    }

    function test_setFacilitatorAuthorizationAdminOnlyAndRejectsZero() public {
        address nextFacilitator = makeAddr("next-facilitator");

        vm.prank(makeAddr("not-admin"));
        vm.expectRevert("not admin");
        adapter.setFacilitatorAuthorization(nextFacilitator, true);

        vm.prank(admin);
        vm.expectRevert("zero facilitator");
        adapter.setFacilitatorAuthorization(address(0), true);
    }

    function test_setFacilitatorAuthorizationSupportsRotationAndRevocation() public {
        address nextFacilitator = makeAddr("next-facilitator");
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IX402Adapter.FacilitatorAuthorizationSet(nextFacilitator, true);
        vm.prank(admin);
        adapter.setFacilitatorAuthorization(nextFacilitator, true);
        assertTrue(adapter.authorizedFacilitators(nextFacilitator));

        vm.prank(admin);
        adapter.setFacilitatorAuthorization(relayer, false);
        assertFalse(adapter.authorizedFacilitators(relayer));

        bytes32 ref = keccak256("revoked");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        vm.prank(relayer);
        vm.expectRevert("facilitator not authorized");
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);
    }

    function test_settleSanctionedSignerRevertsBeforeAuthorization() public {
        bytes32 ref = keccak256("sanctioned-x402");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        sanctions.setSanctioned(buyer, true);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, buyer));
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);

        assertFalse(usdc.authorizationState(buyer, auth.nonce));
        assertEq(usdc.balanceOf(buyer), 1000e6);
        assertEq(router.nextPaymentId(), 1);
    }

    function test_settleBadSignatureReverts() public {
        bytes32 ref = keccak256("ref-bs");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        auth.v = auth.v == 27 ? 28 : 27;
        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);
    }

    function test_settleExpiredAuthReverts() public {
        bytes32 ref = keccak256("ref-expired");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm,
            BUYER_KEY,
            address(usdc),
            buyer,
            address(router),
            100e6,
            0,
            block.timestamp + 10,
            keccak256("expired-random-nonce")
        );
        vm.warp(block.timestamp + 100);
        vm.prank(relayer);
        vm.expectRevert("auth expired");
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, auth);
    }

    function test_settleNonceReplayReverts() public {
        bytes32 ref = keccak256("ref-replay");
        IX402Adapter.EIP3009Auth memory auth = _authFor(50e6, ref, providerAgentId, serviceId);
        vm.prank(relayer);
        adapter.settle(address(usdc), 50e6, ref, providerAgentId, serviceId, auth);

        // Same auth → same bound nonce → token rejects on replay. With the
        // binding in place, a buyer who wants to retry MUST sign a new auth
        // with a fresh serviceRef.
        vm.prank(relayer);
        vm.expectRevert("auth already used");
        adapter.settle(address(usdc), 50e6, ref, providerAgentId, serviceId, auth);
    }

    function test_settleBuyerNoAgentReverts() public {
        // Buyer moves the agent NFT away — the AgentIndex binding goes stale
        // and resolve() returns found=false, so settlement rejects rather than
        // attributing the payment to an agent the wallet no longer controls.
        vm.prank(buyer);
        identity.transferFrom(buyer, makeAddr("elsewhere"), buyerAgentId);
        _assertNotResolved(buyer);

        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, keccak256("ref-na"), providerAgentId, serviceId);
        vm.prank(relayer);
        vm.expectRevert("buyer has no agent");
        adapter.settle(address(usdc), 100e6, keccak256("ref-na"), providerAgentId, serviceId, auth);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(buyer, 100e6);
        bytes32 ref = keccak256("ref-other");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm,
            BUYER_KEY,
            address(other),
            buyer,
            address(router),
            100e6,
            0,
            block.timestamp + 1 hours,
            keccak256("unaccepted-token-random-nonce")
        );
        vm.prank(relayer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(other), 100e6, ref, providerAgentId, serviceId, auth);
    }

    function test_settleFeeOnTransferTokenRevertsAtomically() public {
        FeeOnTransferUSDC feeToken = new FeeOnTransferUSDC();
        feeToken.mint(buyer, 100e6);
        vm.prank(admin);
        router.setAcceptedToken(address(feeToken), true);

        bytes32 ref = keccak256("ref-fee");
        bytes32 nonce = keccak256("fee-token-random-nonce");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(feeToken), buyer, address(router), 100e6, 0, block.timestamp + 1 hours, nonce
        );

        vm.prank(relayer);
        vm.expectRevert("unexpected token amount");
        adapter.settle(address(feeToken), 100e6, ref, providerAgentId, serviceId, auth);

        assertEq(feeToken.balanceOf(buyer), 100e6);
        assertEq(feeToken.balanceOf(address(router)), 0);
        assertFalse(feeToken.authorizationState(buyer, nonce));
        assertFalse(router.paymentKeyUsed(router.computePaymentKey(buyerAgentId, providerAgentId, serviceId, ref)));
        assertEq(router.nextPaymentId(), 1);
    }

    // --- settleWithRegistration (atomic gasless register-and-settle) -----

    uint256 constant FRESH_BUYER_KEY = 0xDA571;

    function _signRegisterAgent(uint256 key, address, string memory uri, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        // Consent signature now targets the AgentIndex domain (the canonical
        // registry has no registerBySig).
        return AgentIndexSigner.signRegisterWithNonce(vm, key, agentIndex, uri, nonce, deadline);
    }

    function _eip3009For(uint256 key, address from, uint256 value, bytes32 serviceRef, uint256, bytes32)
        internal
        view
        returns (IX402Adapter.EIP3009Auth memory)
    {
        return EIP3009Signer.signTransfer(
            vm,
            key,
            address(usdc),
            from,
            address(router),
            value,
            0,
            block.timestamp + 1 hours,
            keccak256(abi.encode("x402-v2-registration-nonce", serviceRef, from))
        );
    }

    function test_settleWithRegistration_unregisteredBuyer() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);

        // No agent yet for freshBuyer.
        _assertNotResolved(freshBuyer);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory regSig = _signRegisterAgent(FRESH_BUYER_KEY, freshBuyer, "ipfs://fresh", 0, deadline);
        bytes32 ref = keccak256("ref-swr-1");
        IX402Adapter.EIP3009Auth memory auth =
            _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, ref, providerAgentId, serviceId);

        vm.prank(relayer);
        (uint256 newBuyerAgentId, uint256 paymentId) = adapter.settleWithRegistration(
            address(usdc), 80e6, ref, providerAgentId, serviceId, auth, "ipfs://fresh", deadline, regSig
        );

        // Registered + paid in one tx. The NFT lands on the buyer wallet
        // (registered via AgentIndex, transferred out in the same call) and
        // the index binding resolves live.
        assertGt(newBuyerAgentId, 0, "buyer registered");
        assertEq(identity.ownerOf(newBuyerAgentId), freshBuyer);
        _assertResolved(freshBuyer, newBuyerAgentId);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, newBuyerAgentId);
        assertEq(rec.amount, 80e6);
        assertEq(rec.serviceId, serviceId);
    }

    function test_settleWithRegistrationSanctionedSignerDoesNotRegisterOrTransfer() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory regSig = _signRegisterAgent(FRESH_BUYER_KEY, freshBuyer, "ipfs://blocked", 0, deadline);
        bytes32 ref = keccak256("sanctioned-registration");
        IX402Adapter.EIP3009Auth memory auth =
            _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, ref, providerAgentId, serviceId);
        sanctions.setSanctioned(freshBuyer, true);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, freshBuyer));
        adapter.settleWithRegistration(
            address(usdc), 80e6, ref, providerAgentId, serviceId, auth, "ipfs://blocked", deadline, regSig
        );

        _assertNotResolved(freshBuyer);
        assertEq(agentIndex.registrationNonce(freshBuyer), 0);
        assertFalse(usdc.authorizationState(freshBuyer, auth.nonce));
        assertEq(usdc.balanceOf(freshBuyer), 100e6);
    }

    function test_settleWithRegistration_alreadyRegisteredSkipsRegistration() public {
        // Existing buyer (from setUp) is already registered.
        // The registration sig + agentURI args should be ignored and the
        // original agentId reused.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory invalidRegSig = hex"deadbeef";
        bytes32 ref = keccak256("ref-swr-2");
        IX402Adapter.EIP3009Auth memory auth = _authFor(50e6, ref, providerAgentId, serviceId);

        vm.prank(relayer);
        (uint256 reusedAgentId, uint256 paymentId) = adapter.settleWithRegistration(
            address(usdc), 50e6, ref, providerAgentId, serviceId, auth, "anything", deadline, invalidRegSig
        );

        assertEq(reusedAgentId, buyerAgentId, "existing agentId reused");
        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
    }

    function test_settleWithRegistration_atomicRevertOnBadRegistration() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory badRegSig = _signRegisterAgent(0xBAD, freshBuyer, "ipfs://x", 0, deadline);
        bytes32 ref = keccak256("ref-swr-3");
        IX402Adapter.EIP3009Auth memory auth =
            _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, ref, providerAgentId, serviceId);

        uint256 freshBuyerUsdcBefore = usdc.balanceOf(freshBuyer);

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settleWithRegistration(
            address(usdc), 80e6, ref, providerAgentId, serviceId, auth, "ipfs://x", deadline, badRegSig
        );

        // Atomicity: nothing moved.
        _assertNotResolved(freshBuyer);
        assertEq(usdc.balanceOf(freshBuyer), freshBuyerUsdcBefore, "no USDC moved");
    }

    function test_settleWithRegistration_atomicRevertOnBadSettlement() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory regSig = _signRegisterAgent(FRESH_BUYER_KEY, freshBuyer, "ipfs://x", 0, deadline);
        bytes32 ref = keccak256("ref-swr-4");
        IX402Adapter.EIP3009Auth memory auth =
            _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, ref, providerAgentId, serviceId);
        // Corrupt the EIP-3009 signature so settlement reverts AFTER
        // registration succeeded inside the same call frame.
        auth.v = auth.v == 27 ? 28 : 27;

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settleWithRegistration(
            address(usdc), 80e6, ref, providerAgentId, serviceId, auth, "ipfs://x", deadline, regSig
        );

        // Atomicity: registration is rolled back along with the failed transfer.
        _assertNotResolved(freshBuyer);
        assertEq(agentIndex.registrationNonce(freshBuyer), 0, "nonce rolled back");
    }
}
