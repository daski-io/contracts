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
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";

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

    function _saltFor(bytes32 serviceRef) internal pure returns (bytes32) {
        return keccak256(abi.encode("x402-v2-salt", serviceRef));
    }

    function _registrationSaltFor(bytes32 serviceRef, address from) internal pure returns (bytes32) {
        return keccak256(abi.encode("x402-v2-registration-salt", serviceRef, from));
    }

    function _authNonceFor(
        address token,
        address payer,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 serviceRef,
        uint256 targetProviderAgentId,
        bytes32 targetServiceId,
        bytes32 nonceSalt
    ) internal view returns (bytes32) {
        return adapter.authNonceFor(
            token,
            payer,
            amount,
            validAfter,
            validBefore,
            serviceRef,
            targetProviderAgentId,
            targetServiceId,
            provider,
            nonceSalt
        );
    }

    function _settleAdapter(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 targetProviderAgentId,
        bytes32 targetServiceId,
        IX402Adapter.EIP3009Auth memory auth,
        bytes32 nonceSalt
    ) internal returns (uint256 paymentId) {
        return adapter.settle(
            token, amount, serviceRef, targetProviderAgentId, targetServiceId, provider, auth, nonceSalt
        );
    }

    function _authFor(uint256 value, bytes32 serviceRef, uint256 targetProviderAgentId, bytes32 targetServiceId)
        internal
        view
        returns (IX402Adapter.EIP3009Auth memory)
    {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = _authNonceFor(
            address(usdc),
            buyer,
            value,
            0,
            validBefore,
            serviceRef,
            targetProviderAgentId,
            targetServiceId,
            _saltFor(serviceRef)
        );
        return EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            value,
            0,
            validBefore,
            nonce
        );
    }

    function _corruptSignature(IX402Adapter.EIP3009Auth memory auth)
        internal
        pure
        returns (IX402Adapter.EIP3009Auth memory)
    {
        auth.signature[0] = bytes1(uint8(auth.signature[0]) ^ 1);
        return auth;
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
        uint256 paymentId = _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));

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

    function test_settleFreshAuthorizationCannotReusePaymentKey() public {
        bytes32 ref = keccak256("duplicate-payment-key");
        IX402Adapter.EIP3009Auth memory firstAuth = _authFor(100e6, ref, providerAgentId, serviceId);
        vm.prank(relayer);
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, firstAuth, _saltFor(ref));

        bytes32 secondSalt = keccak256("fresh-salt");
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 secondNonce =
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, secondSalt);
        IX402Adapter.EIP3009Auth memory secondAuth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            validBefore,
            secondNonce
        );
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(relayer);
        vm.expectRevert("payment key used");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, secondAuth, secondSalt);

        assertFalse(usdc.authorizationState(buyer, secondNonce));
        assertEq(usdc.balanceOf(buyer), buyerBefore);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_settleRejectsNonceUnrelatedToDaskiRouting() public {
        bytes32 ref = keccak256("random-nonce-ref");
        bytes32 nonce = keccak256("official-client-random-nonce");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            block.timestamp + 1 hours,
            nonce
        );

        vm.prank(relayer);
        vm.expectRevert("auth not bound to call");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));

        assertFalse(usdc.authorizationState(buyer, nonce));
    }

    function test_settleRejectsZeroNonceSalt() public {
        bytes32 ref = keccak256("zero-salt");
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce =
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, bytes32(0));
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            validBefore,
            nonce
        );

        vm.prank(relayer);
        vm.expectRevert("zero nonce salt");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, bytes32(0));
        assertFalse(usdc.authorizationState(buyer, nonce));
    }

    function test_authNonceCommitsToEverySettlementFieldAndRandomSalt() public view {
        bytes32 ref = keccak256("bound-route");
        bytes32 salt = _saltFor(ref);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 expected =
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, salt);

        assertNotEq(
            expected,
            _authNonceFor(address(usdc), address(0xBEEF), 100e6, 0, validBefore, ref, providerAgentId, serviceId, salt)
        );
        assertNotEq(
            expected, _authNonceFor(address(usdc), buyer, 101e6, 0, validBefore, ref, providerAgentId, serviceId, salt)
        );
        assertNotEq(
            expected, _authNonceFor(address(usdc), buyer, 100e6, 1, validBefore, ref, providerAgentId, serviceId, salt)
        );
        assertNotEq(
            expected,
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore + 1, ref, providerAgentId, serviceId, salt)
        );
        assertNotEq(
            expected,
            _authNonceFor(
                address(usdc), buyer, 100e6, 0, validBefore, bytes32(uint256(ref) + 1), providerAgentId, serviceId, salt
            )
        );
        assertNotEq(
            expected,
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId + 1, serviceId, salt)
        );
        assertNotEq(
            expected,
            _authNonceFor(
                address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, bytes32(uint256(serviceId) + 1), salt
            )
        );
        assertNotEq(
            expected,
            _authNonceFor(
                address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, bytes32(uint256(salt) + 1)
            )
        );
        assertNotEq(
            expected,
            adapter.authNonceFor(
                address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, address(0xBEEF), salt
            )
        );
    }

    function test_settleRejectsExpectedPayeeNotSignedByBuyer() public {
        bytes32 ref = keccak256("changed-expected-payee");
        bytes32 salt = _saltFor(ref);
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);

        vm.prank(relayer);
        vm.expectRevert("auth not bound to call");
        adapter.settle(address(usdc), 100e6, ref, providerAgentId, serviceId, address(0xBEEF), auth, salt);

        assertFalse(usdc.authorizationState(buyer, auth.nonce));
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_authNonceMatchesSharedBaseSepoliaVector() public pure {
        bytes memory paymentContext = abi.encode(
            keccak256("DASKI_X402_RECEIVE_V1"),
            uint256(84_532),
            address(0xA004),
            address(0xA002),
            address(0xA003),
            0x1111111111111111111111111111111111111111,
            uint256(15_000_000)
        );
        bytes memory routeContext = abi.encode(
            uint256(0),
            uint256(2_000_000_000),
            uint256(2),
            bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222)),
            address(0xBEEF),
            bytes32(uint256(0x3333333333333333333333333333333333333333333333333333333333333333)),
            bytes32(uint256(0x4444444444444444444444444444444444444444444444444444444444444444))
        );
        bytes32 nonce = keccak256(bytes.concat(paymentContext, routeContext));
        assertEq(nonce, 0x6895237ed56c402a03e8bdad76bdaaa360aea6460ca448a08c4bb2afcf8e901e);
    }

    function test_receiveAuthorizationCannotBeFrontRunOutsideAdapter() public {
        bytes32 ref = keccak256("front-run-resistant");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);

        vm.prank(makeAddr("observer"));
        vm.expectRevert("caller must be payee");
        usdc.receiveWithAuthorization(
            auth.from, address(adapter), 100e6, auth.validAfter, auth.validBefore, auth.nonce, auth.signature
        );
        assertFalse(usdc.authorizationState(buyer, auth.nonce));

        vm.prank(relayer);
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));
        assertTrue(usdc.authorizationState(buyer, auth.nonce));
    }

    function test_transferAuthorizationIsNotAcceptedByReceiveProfile() public {
        bytes32 ref = keccak256("wrong-authorization-type");
        bytes32 salt = _saltFor(ref);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce =
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, salt);
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            validBefore,
            nonce
        );

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, salt);
        assertFalse(usdc.authorizationState(buyer, nonce));
    }

    function test_settleUnauthorizedCallerReverts() public {
        bytes32 ref = keccak256("unauthorized");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert("facilitator not authorized");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));
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
            address(usdc),
            80e6,
            ref,
            providerAgentId,
            serviceId,
            provider,
            auth,
            _registrationSaltFor(ref, freshBuyer),
            "ipfs://fresh",
            deadline,
            regSig
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
        assertEq(adapter.getFacilitatorCount(), 2);
        assertEq(adapter.getFacilitatorAt(0), relayer);
        assertEq(adapter.getFacilitatorAt(1), nextFacilitator);

        vm.prank(admin);
        adapter.setFacilitatorAuthorization(nextFacilitator, true);
        assertEq(adapter.getFacilitatorCount(), 2);

        vm.prank(admin);
        adapter.setFacilitatorAuthorization(relayer, false);
        assertFalse(adapter.authorizedFacilitators(relayer));
        assertEq(adapter.getFacilitatorCount(), 1);
        assertEq(adapter.getFacilitatorAt(0), nextFacilitator);

        bytes32 ref = keccak256("revoked");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        vm.prank(relayer);
        vm.expectRevert("facilitator not authorized");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));
    }

    function test_settleSanctionedSignerRevertsBeforeAuthorization() public {
        bytes32 ref = keccak256("sanctioned-x402");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        sanctions.setSanctioned(buyer, true);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, buyer));
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));

        assertFalse(usdc.authorizationState(buyer, auth.nonce));
        assertEq(usdc.balanceOf(buyer), 1000e6);
        assertEq(router.nextPaymentId(), 1);
    }

    function test_settleBadSignatureReverts() public {
        bytes32 ref = keccak256("ref-bs");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);
        auth = _corruptSignature(auth);
        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));
    }

    function test_settleExpiredAuthReverts() public {
        bytes32 ref = keccak256("ref-expired");
        bytes32 salt = _saltFor(ref);
        uint256 validBefore = block.timestamp + 10;
        bytes32 nonce =
            _authNonceFor(address(usdc), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, salt);
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            validBefore,
            nonce
        );
        vm.warp(block.timestamp + 100);
        vm.prank(relayer);
        vm.expectRevert("auth expired");
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, salt);
    }

    function test_settleNonceReplayReverts() public {
        bytes32 ref = keccak256("ref-replay");
        IX402Adapter.EIP3009Auth memory auth = _authFor(50e6, ref, providerAgentId, serviceId);
        vm.prank(relayer);
        _settleAdapter(address(usdc), 50e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));

        // The same authorization cannot be replayed after successful settlement.
        vm.prank(relayer);
        vm.expectRevert("auth already used");
        _settleAdapter(address(usdc), 50e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));
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
        _settleAdapter(
            address(usdc), 100e6, keccak256("ref-na"), providerAgentId, serviceId, auth, _saltFor(keccak256("ref-na"))
        );
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(buyer, 100e6);
        bytes32 ref = keccak256("ref-other");
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(other),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            block.timestamp + 1 hours,
            keccak256("unaccepted-token-random-nonce")
        );
        vm.prank(relayer);
        vm.expectRevert("token not accepted");
        _settleAdapter(address(other), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));
    }

    function test_settleFeeOnTransferTokenRevertsAtomically() public {
        FeeOnTransferUSDC feeToken = new FeeOnTransferUSDC();
        feeToken.mint(buyer, 100e6);
        vm.prank(admin);
        router.setAcceptedToken(address(feeToken), true);

        bytes32 ref = keccak256("ref-fee");
        bytes32 salt = _saltFor(ref);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce =
            _authNonceFor(address(feeToken), buyer, 100e6, 0, validBefore, ref, providerAgentId, serviceId, salt);
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            BUYER_KEY,
            address(feeToken),
            "USDC",
            "2",
            block.chainid,
            buyer,
            address(adapter),
            100e6,
            0,
            validBefore,
            nonce
        );

        vm.prank(relayer);
        vm.expectRevert("unexpected token amount");
        _settleAdapter(address(feeToken), 100e6, ref, providerAgentId, serviceId, auth, salt);

        assertEq(feeToken.balanceOf(buyer), 100e6);
        assertEq(feeToken.balanceOf(address(router)), 0);
        assertFalse(feeToken.authorizationState(buyer, nonce));
        assertFalse(router.paymentKeyUsed(router.computePaymentKey(buyerAgentId, providerAgentId, serviceId, ref)));
        assertEq(router.nextPaymentId(), 1);
    }

    function test_settlePreservesPreexistingAdapterAndRouterBalances() public {
        uint256 adapterDust = 7;
        uint256 routerDust = 11;
        usdc.mint(address(adapter), adapterDust);
        usdc.mint(address(router), routerDust);
        bytes32 ref = keccak256("preexisting-balances");
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, ref, providerAgentId, serviceId);

        vm.prank(relayer);
        _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, _saltFor(ref));

        assertEq(usdc.balanceOf(address(adapter)), adapterDust);
        assertEq(usdc.balanceOf(address(router)), routerDust);
        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6);
    }

    function test_settleSupportsERC1271BuyerAuthorization() public {
        uint256 walletOwnerKey = 0x1271;
        MockERC1271Wallet wallet = new MockERC1271Wallet(vm.addr(walletOwnerKey));
        vm.prank(address(wallet));
        uint256 walletAgentId = identity.register();
        vm.prank(address(wallet));
        agentIndex.claim(walletAgentId);
        usdc.mint(address(wallet), 100e6);

        bytes32 ref = keccak256("erc1271-buyer");
        bytes32 salt = keccak256("erc1271-salt");
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce =
            _authNonceFor(address(usdc), address(wallet), 100e6, 0, validBefore, ref, providerAgentId, serviceId, salt);
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signReceive(
            vm,
            walletOwnerKey,
            address(usdc),
            "USDC",
            "2",
            block.chainid,
            address(wallet),
            address(adapter),
            100e6,
            0,
            validBefore,
            nonce
        );

        vm.prank(relayer);
        uint256 paymentId = _settleAdapter(address(usdc), 100e6, ref, providerAgentId, serviceId, auth, salt);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, walletAgentId);
        assertEq(rec.cachedBuyerWallet, address(wallet));
        assertEq(usdc.balanceOf(address(wallet)), 0);
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

    function _eip3009For(
        uint256 key,
        address from,
        uint256 value,
        bytes32 serviceRef,
        uint256 targetProviderAgentId,
        bytes32 targetServiceId
    ) internal view returns (IX402Adapter.EIP3009Auth memory) {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = _authNonceFor(
            address(usdc),
            from,
            value,
            0,
            validBefore,
            serviceRef,
            targetProviderAgentId,
            targetServiceId,
            _registrationSaltFor(serviceRef, from)
        );
        return EIP3009Signer.signReceive(
            vm, key, address(usdc), "USDC", "2", block.chainid, from, address(adapter), value, 0, validBefore, nonce
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
            address(usdc),
            80e6,
            ref,
            providerAgentId,
            serviceId,
            provider,
            auth,
            _registrationSaltFor(ref, freshBuyer),
            "ipfs://fresh",
            deadline,
            regSig
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
            address(usdc),
            80e6,
            ref,
            providerAgentId,
            serviceId,
            provider,
            auth,
            _registrationSaltFor(ref, freshBuyer),
            "ipfs://blocked",
            deadline,
            regSig
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
            address(usdc),
            50e6,
            ref,
            providerAgentId,
            serviceId,
            provider,
            auth,
            _saltFor(ref),
            "anything",
            deadline,
            invalidRegSig
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
            address(usdc),
            80e6,
            ref,
            providerAgentId,
            serviceId,
            provider,
            auth,
            _registrationSaltFor(ref, freshBuyer),
            "ipfs://x",
            deadline,
            badRegSig
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
        auth = _corruptSignature(auth);

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settleWithRegistration(
            address(usdc),
            80e6,
            ref,
            providerAgentId,
            serviceId,
            provider,
            auth,
            _registrationSaltFor(ref, freshBuyer),
            "ipfs://x",
            deadline,
            regSig
        );

        // Atomicity: registration is rolled back along with the failed transfer.
        _assertNotResolved(freshBuyer);
        assertEq(agentIndex.registrationNonce(freshBuyer), 0, "nonce rolled back");
    }
}
