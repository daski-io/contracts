// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal pass-through adapter used ONLY by the router unit tests so
/// we can exercise `settle` in isolation from any specific payment rail.
/// Funds are transferred via plain `transferFrom` before calling settle.
contract PassThroughAdapter {
    using SafeERC20 for IERC20;

    PaymentRouter public immutable router;

    constructor(PaymentRouter _router) {
        router = _router;
    }

    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 buyerAgentId,
        address buyerWallet,
        uint256 providerAgentId,
        bytes32 serviceId
    ) external returns (uint256 paymentId) {
        IERC20(token).safeTransferFrom(msg.sender, address(router), amount);
        return router.settle(token, amount, serviceRef, buyerAgentId, buyerWallet, providerAgentId, serviceId);
    }
}

contract PaymentRouterHandler {
    MockUSDC private immutable TOKEN;
    PassThroughAdapter private immutable ADAPTER;
    uint256 private immutable BUYER_AGENT_ID;
    uint256 private immutable PROVIDER_AGENT_ID;
    bytes32 private immutable SERVICE_ID;

    uint256 public totalSettled;
    uint256 private settlementNonce;

    constructor(
        MockUSDC token,
        PassThroughAdapter paymentAdapter,
        MockCanonicalIdentityRegistry identity,
        uint256 providerAgentId,
        bytes32 serviceId
    ) {
        TOKEN = token;
        ADAPTER = paymentAdapter;
        PROVIDER_AGENT_ID = providerAgentId;
        SERVICE_ID = serviceId;
        BUYER_AGENT_ID = identity.register();
        token.approve(address(paymentAdapter), type(uint256).max);
    }

    function settle(uint96 rawAmount) external {
        uint256 amount = (uint256(rawAmount) % 1e6) + 1;
        bytes32 serviceRef = keccak256(abi.encode(settlementNonce++));
        ADAPTER.settle(address(TOKEN), amount, serviceRef, BUYER_AGENT_ID, address(this), PROVIDER_AGENT_ID, SERVICE_ID);
        totalSettled += amount;
    }
}

contract ToggleReputationSink {
    address private immutable PAYMENT_ROUTER;
    bool public failPayment;
    bool public failRefund;

    constructor(address paymentRouter_) {
        PAYMENT_ROUTER = paymentRouter_;
    }

    function paymentRouter() external view returns (address) {
        return PAYMENT_ROUTER;
    }

    function isConfigured() external pure returns (bool) {
        return true;
    }

    function setFailRefund(bool fail) external {
        failRefund = fail;
    }

    function setFailPayment(bool fail) external {
        failPayment = fail;
    }

    function recordPayment(uint256) external view {
        require(!failPayment, "payment mirror failed");
    }

    function recordRefund(uint256, uint256) external view {
        require(!failRefund, "refund mirror failed");
    }
}

contract UnconfiguredReputationSink {
    address private immutable PAYMENT_ROUTER;

    constructor(address paymentRouter_) {
        PAYMENT_ROUTER = paymentRouter_;
    }

    function paymentRouter() external view returns (address) {
        return PAYMENT_ROUTER;
    }

    function isConfigured() external pure returns (bool) {
        return false;
    }

    function recordPayment(uint256) external {}

    function recordRefund(uint256, uint256) external {}
}

contract PaymentRouterTest is Test {
    MockCanonicalIdentityRegistry identity;
    ProviderRegistry registry;
    ServiceRegistry serviceRegistry;
    PaymentRouter router;
    MockUSDC usdc;
    PassThroughAdapter adapter;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address buyer = makeAddr("buyer");

    uint256 providerAgentId;
    uint256 buyerAgentId;
    bytes32 serviceId;
    PaymentRouterHandler handler;
    uint256 invariantRecipientBalanceBefore;

    event PaymentSettled(
        uint256 indexed paymentId,
        bytes32 indexed serviceRef,
        bytes32 indexed serviceId,
        uint256 buyerAgentId,
        uint256 providerAgentId,
        address token,
        uint256 totalAmount,
        uint256 providerAmount,
        uint256 commission
    );
    event Refunded(uint256 indexed paymentId, uint256 amountToBuyer, uint256 cumulativeRefunded);
    event AdapterSet(address indexed adapter, bool allowed);
    event AcceptedTokenSet(address indexed token, bool allowed);
    event CommissionUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    function setUp() public {
        usdc = new MockUSDC();

        // Stand-in for the canonical ERC-8004 IdentityRegistry singleton.
        identity = new MockCanonicalIdentityRegistry();

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
        serviceRegistry = ServiceRegistry(
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
                        (address(identity), address(registry), address(serviceRegistry), treasury, 500, admin)
                    )
                )
            )
        );

        adapter = new PassThroughAdapter(router);
        ToggleReputationSink sink = new ToggleReputationSink(address(router));
        vm.prank(admin);
        router.setReputationStorage(address(sink));
        vm.prank(admin);
        router.setAdapter(address(adapter), true);
        vm.prank(admin);
        router.setAcceptedToken(address(usdc), true);

        // Provider registers as ERC-8004 agent and lists with Daski.
        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example.com/agent.json");
        // Keep the provider wallet explicit in this fixture.
        identity.forceSetAgentWallet(providerAgentId, provider);

        usdc.mint(provider, 1_000_000);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1_000_000);
        registry.register(providerAgentId);
        vm.stopPrank();

        // Register a default service for this provider.
        vm.prank(provider);
        serviceId = serviceRegistry.registerService(providerAgentId, "skill", "1", "ipfs://meta", address(0));

        vm.prank(buyer);
        buyerAgentId = identity.register();
        usdc.mint(buyer, 1000e6);

        handler = new PaymentRouterHandler(usdc, adapter, identity, providerAgentId, serviceId);
        usdc.mint(address(handler), 1e18);
        invariantRecipientBalanceBefore = usdc.balanceOf(provider) + usdc.balanceOf(treasury);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.settle.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _settle(uint256 amount, bytes32 ref) internal returns (uint256 paymentId) {
        return _settleWithService(amount, ref, serviceId);
    }

    function _settleWithService(uint256 amount, bytes32 ref, bytes32 svcId) internal returns (uint256 paymentId) {
        vm.prank(buyer);
        usdc.approve(address(adapter), amount);
        vm.prank(buyer);
        paymentId = adapter.settle(address(usdc), amount, ref, buyerAgentId, buyer, providerAgentId, svcId);
    }

    // ── Settle (happy path) ──────────────────────────────────────────

    function test_settleHappyPath() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        uint256 paymentId = _settle(100e6, keccak256("ref-1"));

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 5e6);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(rec.providerAgentId, providerAgentId);
        assertEq(rec.serviceId, serviceId, "serviceId persisted on PaymentRecord");
        assertEq(rec.amount, 100e6);
        assertEq(rec.token, address(usdc));
        assertEq(rec.cachedBuyerWallet, buyer);
        assertEq(rec.cachedProviderOwner, provider);
        assertEq(rec.cachedProviderWallet, provider);
        assertEq(rec.serviceRef, keccak256("ref-1"));
        assertEq(rec.paidAt, block.timestamp, "paidAt captures settlement timestamp");
        assertTrue(rec.reputationEligible);

        assertEq(router.nextPaymentId(), paymentId + 1);
        bytes32 paymentKey = router.computePaymentKey(buyerAgentId, providerAgentId, serviceId, keccak256("ref-1"));
        assertTrue(router.paymentKeyUsed(paymentKey));
    }

    function test_settleEmitsEvent() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.expectEmit(true, true, true, true, address(router));
        emit PaymentSettled(
            1, keccak256("ref-1"), serviceId, buyerAgentId, providerAgentId, address(usdc), 100e6, 95e6, 5e6
        );
        vm.prank(buyer);
        adapter.settle(address(usdc), 100e6, keccak256("ref-1"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    // L-7: settle pays the LIVE agentWallet from the IdentityRegistry and
    // follows agentWallet rotation. Without this, a provider that rotates their
    // agentWallet for refund/auth purposes would still receive payments at the
    // old address.
    function test_settle_paysLiveAgentWalletAfterRotation() public {
        // Provider rotates agentWallet via setAgentWallet to a fresh wallet.
        uint256 newKey = 0xFEED;
        address newWallet = vm.addr(newKey);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _signSetAgentWallet(newKey, providerAgentId, newWallet, deadline);

        vm.prank(provider);
        identity.setAgentWallet(providerAgentId, newWallet, deadline, sig);

        assertEq(identity.getAgentWallet(providerAgentId), newWallet);

        uint256 newWalletBefore = usdc.balanceOf(newWallet);
        uint256 oldWalletBefore = usdc.balanceOf(provider);

        _settle(100e6, keccak256("ref-rotation"));

        // Payment lands at the LIVE agentWallet, not the stale registry wallet.
        assertEq(usdc.balanceOf(newWallet) - newWalletBefore, 95e6);
        assertEq(usdc.balanceOf(provider), oldWalletBefore, "stale wallet untouched");
    }

    function test_settle_revertsWhenAgentWalletUnset() public {
        // After audit finding H-1: if the provider unsets their agentWallet,
        // settle MUST revert. The payee is resolved solely from the live
        // ERC-8004 agentWallet (there is no Daski-local wallet fallback), so an
        // unset wallet leaves no payee. Per ERC-8004 the new owner must re-bind
        // a wallet after a transfer before payments can resume.
        vm.prank(provider);
        identity.unsetAgentWallet(providerAgentId);
        assertEq(identity.getAgentWallet(providerAgentId), address(0));

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("no payee wallet");
        adapter.settle(address(usdc), 100e6, keccak256("ref-fallback"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    /// H-1 regression test: after the agent NFT is transferred, the new
    /// owner has not yet bound a wallet. Settle must revert until they do —
    /// the payee comes only from the live ERC-8004 agentWallet, which is
    /// cleared on transfer.
    function test_settle_revertsAfterNftTransferUntilNewOwnerBindsWallet() public {
        address newOwner = makeAddr("newOwner");

        // Provider sells the NFT.
        vm.prank(provider);
        identity.transferFrom(provider, newOwner, providerAgentId);
        assertEq(identity.ownerOf(providerAgentId), newOwner);
        assertEq(identity.getAgentWallet(providerAgentId), address(0), "wallet cleared on transfer");

        // Buyer attempts to pay — must revert until the new owner binds a wallet.
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("no payee wallet");
        adapter.settle(address(usdc), 100e6, keccak256("ref-h1"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    function test_settleIgnoresServiceWalletAuthorizedByFormerOwner() public {
        address oldOverride = makeAddr("oldOverride");
        vm.prank(provider);
        serviceRegistry.setServiceWallet(serviceId, oldOverride);

        address newOwner = makeAddr("newProviderOwner");
        vm.prank(provider);
        identity.transferFrom(provider, newOwner, providerAgentId);

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("no payee wallet");
        adapter.settle(
            address(usdc), 100e6, keccak256("stale-service-wallet"), buyerAgentId, buyer, providerAgentId, serviceId
        );
        assertEq(usdc.balanceOf(oldOverride), 0);

        vm.prank(newOwner);
        identity.forceSetAgentWallet(providerAgentId, newOwner);
        _settle(100e6, keccak256("new-owner-wallet"));
        assertEq(usdc.balanceOf(newOwner), 95e6);
        assertEq(usdc.balanceOf(oldOverride), 0);
    }

    function test_settleDoesNotReactivateServiceWalletAfterOwnershipRoundTrip() public {
        address oldOverride = makeAddr("oldOverride");
        vm.prank(provider);
        serviceRegistry.setServiceWallet(serviceId, oldOverride);

        address interimOwner = makeAddr("interimOwner");
        vm.prank(provider);
        identity.transferFrom(provider, interimOwner, providerAgentId);
        vm.prank(interimOwner);
        identity.transferFrom(interimOwner, provider, providerAgentId);

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("no payee wallet");
        adapter.settle(
            address(usdc), 100e6, keccak256("ownership-round-trip"), buyerAgentId, buyer, providerAgentId, serviceId
        );
        assertEq(usdc.balanceOf(oldOverride), 0);

        address freshWallet = makeAddr("freshProviderWallet");
        identity.forceSetAgentWallet(providerAgentId, freshWallet);
        _settle(100e6, keccak256("fresh-wallet-after-round-trip"));
        assertEq(usdc.balanceOf(freshWallet), 95e6);
        assertEq(usdc.balanceOf(oldOverride), 0);
    }

    function _signSetAgentWallet(uint256 key, uint256 agentId, address newWallet, uint256 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        address owner = identity.ownerOf(agentId);
        bytes32 structHash =
            keccak256(abi.encode(identity.SET_AGENT_WALLET_TYPEHASH(), agentId, newWallet, owner, deadline));
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ERC8004IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(identity)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // ── Settle (service / token enforcement) ─────────────────────────

    function test_settle_serviceMismatchReverts() public {
        // Register a service against a DIFFERENT provider, then try to
        // settle that serviceId against our provider. Should revert.
        address otherProv = makeAddr("otherProv");
        vm.prank(otherProv);
        uint256 otherAgent = identity.register("u");
        usdc.mint(otherProv, 1_000_000);
        vm.startPrank(otherProv);
        usdc.approve(address(registry), 1_000_000);
        registry.register(otherAgent);
        vm.stopPrank();
        vm.prank(otherProv);
        bytes32 otherSvc = serviceRegistry.registerService(otherAgent, "skill", "1", "u", address(0));

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("service/provider mismatch");
        adapter.settle(address(usdc), 100e6, keccak256("ref-mm"), buyerAgentId, buyer, providerAgentId, otherSvc);
    }

    function test_settle_inactiveServiceReverts() public {
        vm.prank(provider);
        serviceRegistry.setActive(serviceId, false);

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("service not active");
        adapter.settle(address(usdc), 100e6, keccak256("ref-inactive"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    function test_settle_unknownServiceReverts() public {
        bytes32 ghost = keccak256("does-not-exist");
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("service not found");
        adapter.settle(address(usdc), 100e6, keccak256("ref-ghost"), buyerAgentId, buyer, providerAgentId, ghost);
    }

    function test_settle_serviceWalletPayee() public {
        // Set a per-service payee override. Funds should land at the
        // override, not at the provider's agentWallet.
        address svcWallet = makeAddr("serviceWallet");
        vm.prank(provider);
        serviceRegistry.setServiceWallet(serviceId, svcWallet);

        uint256 svcWalletBefore = usdc.balanceOf(svcWallet);
        uint256 providerBefore = usdc.balanceOf(provider);

        _settle(100e6, keccak256("ref-svcw"));

        assertEq(usdc.balanceOf(svcWallet) - svcWalletBefore, 95e6);
        assertEq(usdc.balanceOf(provider), providerBefore, "provider untouched");
    }

    function test_settle_serviceWalletZero_inheritsAgentWallet() public {
        // Default serviceWallet=0 → fall back to provider's agentWallet.
        // (This is the happy path test re-stated as a fallback assertion.)
        assertEq(serviceRegistry.getService(serviceId).serviceWallet, address(0));

        uint256 providerBefore = usdc.balanceOf(provider);
        _settle(100e6, keccak256("ref-fb"));
        assertEq(usdc.balanceOf(provider) - providerBefore, 95e6);
    }

    function test_settleNonAdapterReverts() public {
        vm.expectRevert("not adapter");
        router.settle(address(usdc), 100e6, keccak256("ref"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC otherToken = new MockUSDC();
        otherToken.mint(buyer, 100e6);
        vm.prank(buyer);
        otherToken.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(otherToken), 100e6, keccak256("ref"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    function test_settleZeroAmountReverts() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 100);
        vm.prank(buyer);
        vm.expectRevert("zero amount");
        adapter.settle(address(usdc), 0, keccak256("ref"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    function test_settleSupportsAgentIdZero() public {
        assertEq(providerAgentId, 0, "canonical IDs start at zero");
        usdc.mint(provider, 100e6);
        vm.prank(provider);
        usdc.approve(address(adapter), 100e6);
        vm.prank(provider);
        uint256 paymentId =
            adapter.settle(address(usdc), 100e6, keccak256("ref-zero"), 0, provider, providerAgentId, serviceId);
        assertEq(router.getPayment(paymentId).buyerAgentId, 0);
        assertFalse(router.getPayment(paymentId).reputationEligible, "self-payment is not reputation");
    }

    function test_settleTinyPaymentDoesNotCreateReputation() public {
        uint256 paymentId = _settle(router.MINIMUM_REPUTATION_AMOUNT() - 1, keccak256("tiny"));
        assertFalse(router.getPayment(paymentId).reputationEligible);
    }

    function test_settleAtReputationFloorIsEligible() public {
        uint256 paymentId = _settle(router.MINIMUM_REPUTATION_AMOUNT(), keccak256("floor"));
        assertTrue(router.getPayment(paymentId).reputationEligible);
    }

    function test_settleSharedControllerDoesNotCreateReputation() public {
        vm.prank(provider);
        uint256 controlledBuyerAgentId = identity.register("controlled-buyer");
        usdc.mint(provider, 1e6);
        vm.prank(provider);
        usdc.approve(address(adapter), 1e6);
        vm.prank(provider);
        uint256 paymentId = adapter.settle(
            address(usdc),
            1e6,
            keccak256("shared-controller"),
            controlledBuyerAgentId,
            provider,
            providerAgentId,
            serviceId
        );
        assertFalse(router.getPayment(paymentId).reputationEligible);
    }

    function testFuzz_settleConservesFundsAndClassifiesReputation(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 100e6);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 paymentId = _settle(amount, keccak256(abi.encode(rawAmount)));

        assertEq(usdc.balanceOf(provider) - providerBefore + usdc.balanceOf(treasury) - treasuryBefore, amount);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(router.getPayment(paymentId).reputationEligible, amount >= router.MINIMUM_REPUTATION_AMOUNT());
    }

    function test_settleZeroBuyerWalletReverts() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("zero buyer wallet");
        adapter.settle(address(usdc), 100e6, keccak256("ref-zw"), buyerAgentId, address(0), providerAgentId, serviceId);
    }

    function test_settleBuyerWalletMismatchReverts() public {
        // A buggy adapter passing a wallet unrelated to the buyer agent must
        // be rejected — it would otherwise become the refund destination.
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("buyer wallet mismatch");
        adapter.settle(
            address(usdc), 100e6, keccak256("ref-wm"), buyerAgentId, makeAddr("unrelated"), providerAgentId, serviceId
        );
    }

    function test_settleReuseServiceRefReverts() public {
        _settle(50e6, keccak256("dup"));
        vm.prank(buyer);
        usdc.approve(address(adapter), 50e6);
        vm.prank(buyer);
        vm.expectRevert("payment key used");
        adapter.settle(address(usdc), 50e6, keccak256("dup"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    function test_settleSameServiceRefFromDifferentBuyerSucceeds() public {
        bytes32 sharedRef = keccak256("shared-reference");
        _settle(50e6, sharedRef);

        address secondBuyer = makeAddr("secondBuyer");
        vm.prank(secondBuyer);
        uint256 secondBuyerAgentId = identity.register();
        usdc.mint(secondBuyer, 50e6);

        vm.prank(secondBuyer);
        usdc.approve(address(adapter), 50e6);
        vm.prank(secondBuyer);
        uint256 secondPaymentId =
            adapter.settle(address(usdc), 50e6, sharedRef, secondBuyerAgentId, secondBuyer, providerAgentId, serviceId);

        assertEq(secondPaymentId, 2);
        assertTrue(router.paymentKeyUsed(router.computePaymentKey(buyerAgentId, providerAgentId, serviceId, sharedRef)));
        assertTrue(
            router.paymentKeyUsed(router.computePaymentKey(secondBuyerAgentId, providerAgentId, serviceId, sharedRef))
        );
    }

    function test_settleInactiveProviderReverts() public {
        vm.prank(provider);
        registry.setActive(providerAgentId, false);

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("provider not active");
        adapter.settle(address(usdc), 100e6, keccak256("ref"), buyerAgentId, buyer, providerAgentId, serviceId);
    }

    // ── Refund (happy path) ──────────────────────────────────────────

    function test_refundFullHappyPath() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-r"));
        assertEq(usdc.balanceOf(provider), 95e6);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(provider);
        usdc.approve(address(router), 95e6);

        vm.expectEmit(true, true, true, true, address(router));
        emit Refunded(paymentId, 95e6, 95e6);
        vm.prank(provider);
        router.refund(paymentId, 95e6);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, 95e6);
        assertEq(router.refundedAmount(paymentId), 95e6);
    }

    function test_refundPartial() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-part"));
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(provider);
        usdc.approve(address(router), 40e6);

        vm.prank(provider);
        router.refund(paymentId, 40e6);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, 40e6);
        assertEq(router.refundedAmount(paymentId), 40e6);
    }

    function test_refundCumulative() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-cum"));
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(provider);
        usdc.approve(address(router), 90e6);

        vm.prank(provider);
        router.refund(paymentId, 30e6);
        vm.prank(provider);
        router.refund(paymentId, 60e6);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, 90e6);
        assertEq(router.refundedAmount(paymentId), 90e6);
    }

    function test_refundOverLimitReverts() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-over"));
        vm.prank(provider);
        usdc.approve(address(router), 101e6);
        vm.prank(provider);
        vm.expectRevert("exceeds refundable amount");
        router.refund(paymentId, 101e6);
    }

    function test_refundCumulativeOverLimitReverts() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-cumover"));
        vm.prank(provider);
        usdc.approve(address(router), 100e6);
        vm.prank(provider);
        router.refund(paymentId, 60e6);

        vm.prank(provider);
        vm.expectRevert("exceeds refundable amount");
        router.refund(paymentId, 50e6);
    }

    function test_refundNonProviderReverts() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-np"));
        vm.prank(buyer);
        vm.expectRevert("not authorized for provider");
        router.refund(paymentId, 10e6);

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert("not authorized for provider");
        router.refund(paymentId, 10e6);
    }

    // Refund auth surface: NFT owner, isApprovedForAll operator, per-token
    // approved spender, and the live agentWallet are all authorized. Funds
    // come from msg.sender's approved balance — they cannot drain the
    // provider's agentWallet.

    function test_refund_byNftOwner() public {
        // The default provider wallet IS both the NFT owner AND the
        // agentWallet, so we already cover this in test_refundFullHappyPath.
        // This test asserts the path explicitly: rotate the agentWallet to
        // a different address so "owner" and "agentWallet" are distinct,
        // then refund as the owner — must succeed via the owner branch.
        uint256 newKey = 0x1111;
        address newWallet = vm.addr(newKey);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _signSetAgentWallet(newKey, providerAgentId, newWallet, deadline);
        vm.prank(provider);
        identity.setAgentWallet(providerAgentId, newWallet, deadline, sig);

        // Provider received via the LIVE agentWallet (newWallet) at settle.
        // For the refund the owner pulls from THEIR OWN approved balance —
        // mint provider some USDC and approve the router.
        usdc.mint(provider, 50e6);
        vm.prank(provider);
        usdc.approve(address(router), 50e6);

        uint256 paymentId = _settle(100e6, keccak256("ref-owner"));
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(provider);
        router.refund(paymentId, 50e6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 50e6);
    }

    function test_refund_byOperator_isApprovedForAll() public {
        address op = makeAddr("op");
        vm.prank(provider);
        identity.setApprovalForAll(op, true);

        uint256 paymentId = _settle(100e6, keccak256("ref-op"));
        usdc.mint(op, 50e6);
        vm.prank(op);
        usdc.approve(address(router), 50e6);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(op);
        router.refund(paymentId, 50e6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 50e6);
        // Source of funds: operator's own balance, not the provider's.
        assertEq(usdc.balanceOf(op), 0);
    }

    function test_refund_byApprovedSpender_perToken() public {
        address spender = makeAddr("spender");
        vm.prank(provider);
        identity.approve(spender, providerAgentId);

        uint256 paymentId = _settle(100e6, keccak256("ref-sp"));
        usdc.mint(spender, 25e6);
        vm.prank(spender);
        usdc.approve(address(router), 25e6);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(spender);
        router.refund(paymentId, 25e6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 25e6);
    }

    function test_refund_byCurrentAgentWallet() public {
        // Default agentWallet IS the provider EOA, so this is what the
        // happy path already exercises. Re-state explicitly for the audit
        // trail: refund initiated by current agentWallet succeeds.
        uint256 paymentId = _settle(100e6, keccak256("ref-aw"));
        vm.prank(provider);
        usdc.approve(address(router), 50e6);
        vm.prank(provider);
        router.refund(paymentId, 50e6);
        assertEq(router.refundedAmount(paymentId), 50e6);
    }

    function test_refund_byRotatedOutWallet_reverts() public {
        // Provider rotates agentWallet. The OLD wallet still holds the
        // funds from settle (since settle paid the NEW wallet only after
        // rotation), but old wallet is no longer authorized to refund.
        uint256 paymentId = _settle(100e6, keccak256("ref-rotated"));

        uint256 newKey = 0x2222;
        address newWallet = vm.addr(newKey);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _signSetAgentWallet(newKey, providerAgentId, newWallet, deadline);
        vm.prank(provider);
        identity.setAgentWallet(providerAgentId, newWallet, deadline, sig);

        // Mint the OLD wallet (which used to be agentWallet) some USDC
        // and try to refund — must revert because the provider's live
        // agentWallet is read at call time.
        usdc.mint(provider, 50e6);
        vm.prank(provider);
        usdc.approve(address(router), 50e6);
        // Note: provider IS still the NFT owner, so they would actually
        // succeed via the owner branch. Test that case below by transferring
        // the NFT to a new owner first so neither owner-branch nor
        // agentWallet-branch authorizes msg.sender.
        address strangerOwner = makeAddr("stranger");
        vm.prank(provider);
        identity.transferFrom(provider, strangerOwner, providerAgentId);

        vm.prank(provider);
        vm.expectRevert("not authorized for provider");
        router.refund(paymentId, 25e6);
    }

    function test_refundZeroReverts() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-z"));
        vm.prank(provider);
        vm.expectRevert("zero refund");
        router.refund(paymentId, 0);
    }

    function test_refundUnknownPaymentReverts() public {
        vm.prank(provider);
        vm.expectRevert("payment not found");
        router.refund(999, 1);
    }

    function test_refundReturnsToOriginalPayerAfterAgentTransfer() public {
        uint256 paymentId = _settle(100e6, keccak256("ref-unset"));

        address newOwner = makeAddr("newBuyerOwner");
        vm.prank(buyer);
        identity.transferFrom(buyer, newOwner, buyerAgentId);
        vm.prank(newOwner);
        identity.forceSetAgentWallet(buyerAgentId, newOwner);

        vm.prank(provider);
        usdc.approve(address(router), 50e6);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 newOwnerBefore = usdc.balanceOf(newOwner);
        vm.prank(provider);
        router.refund(paymentId, 50e6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 50e6, "original payer receives refund");
        assertEq(usdc.balanceOf(newOwner), newOwnerBefore, "new agent owner cannot redirect old refund");
    }

    function test_refundSucceedsWhenReputationSinkFailsAndCanRetry() public {
        ToggleReputationSink sink = new ToggleReputationSink(address(router));
        vm.prank(admin);
        router.setReputationStorage(address(sink));

        uint256 paymentId = _settle(100e6, keccak256("atomic-refund"));
        sink.setFailRefund(true);

        vm.prank(provider);
        usdc.approve(address(router), 50e6);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(provider);
        router.refund(paymentId, 50e6);

        assertEq(router.refundedAmount(paymentId), 50e6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 50e6);
        assertEq(providerBefore - usdc.balanceOf(provider), 50e6);
        (bool paymentSynced, uint256 refundSynced) = router.reputationSyncState(paymentId);
        assertTrue(paymentSynced);
        assertEq(refundSynced, 0);

        vm.expectRevert("refund mirror failed");
        router.syncReputation(paymentId);
        sink.setFailRefund(false);
        router.syncReputation(paymentId);
        (paymentSynced, refundSynced) = router.reputationSyncState(paymentId);
        assertTrue(paymentSynced);
        assertEq(refundSynced, 50e6);
    }

    function test_settleSucceedsWhenReputationSinkFailsAndCanRetry() public {
        ToggleReputationSink sink = new ToggleReputationSink(address(router));
        sink.setFailPayment(true);
        vm.prank(admin);
        router.setReputationStorage(address(sink));

        uint256 paymentId = _settle(100e6, keccak256("retry-payment"));
        (bool paymentSynced,) = router.reputationSyncState(paymentId);
        assertFalse(paymentSynced);

        vm.expectRevert("payment mirror failed");
        router.syncReputation(paymentId);
        sink.setFailPayment(false);
        router.syncReputation(paymentId);
        (paymentSynced,) = router.reputationSyncState(paymentId);
        assertTrue(paymentSynced);
    }

    function test_reputationStorageCannotChangeAfterPayment() public {
        _settle(1e6, keccak256("lock-reputation"));
        vm.prank(admin);
        vm.expectRevert("payments already exist");
        router.setReputationStorage(makeAddr("replacement"));
    }

    // ── Admin ────────────────────────────────────────────────────────

    function test_setAdapter() public {
        address someAdapter = address(new PassThroughAdapter(router));
        assertFalse(router.isAdapter(someAdapter));

        vm.expectEmit(true, true, true, true, address(router));
        emit AdapterSet(someAdapter, true);
        vm.prank(admin);
        router.setAdapter(someAdapter, true);
        assertTrue(router.isAdapter(someAdapter));
        assertEq(router.getAdapterCount(), 2);

        vm.prank(admin);
        router.setAdapter(someAdapter, false);
        assertFalse(router.isAdapter(someAdapter));
        assertEq(router.getAdapterCount(), 1);
    }

    function test_setAdapterZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert("zero adapter");
        router.setAdapter(address(0), true);
    }

    function test_setAdapterWithoutCodeReverts() public {
        vm.prank(admin);
        vm.expectRevert("adapter has no code");
        router.setAdapter(makeAddr("eoaAdapter"), true);
    }

    function test_setAcceptedToken() public {
        address someToken = address(new MockUSDC());
        vm.expectEmit(true, true, true, true, address(router));
        emit AcceptedTokenSet(someToken, true);
        vm.prank(admin);
        router.setAcceptedToken(someToken, true);
        assertTrue(router.isAcceptedToken(someToken));
    }

    function test_setAcceptedTokenZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert("zero token");
        router.setAcceptedToken(address(0), true);
    }

    function test_setAcceptedTokenWithoutCodeReverts() public {
        vm.prank(admin);
        vm.expectRevert("token has no code");
        router.setAcceptedToken(makeAddr("eoaToken"), true);
    }

    function test_paymentEntryPointsRequireReputationConfiguration() public {
        PaymentRouter freshImpl = new PaymentRouter();
        PaymentRouter fresh = PaymentRouter(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(
                        PaymentRouter.initialize,
                        (address(identity), address(registry), address(serviceRegistry), treasury, 500, admin)
                    )
                )
            )
        );

        vm.prank(admin);
        vm.expectRevert("reputation not configured");
        fresh.setAdapter(address(adapter), true);

        vm.prank(admin);
        vm.expectRevert("reputation not configured");
        fresh.setAcceptedToken(address(usdc), true);
    }

    function test_setReputationStorageRejectsInvalidAddress() public {
        vm.prank(admin);
        vm.expectRevert("zero reputation storage");
        router.setReputationStorage(address(0));

        vm.prank(admin);
        vm.expectRevert("reputation storage has no code");
        router.setReputationStorage(makeAddr("eoaSink"));

        UnconfiguredReputationSink unconfigured = new UnconfiguredReputationSink(address(router));
        vm.prank(admin);
        vm.expectRevert("reputation not configured");
        router.setReputationStorage(address(unconfigured));

        ToggleReputationSink wrongRouter = new ToggleReputationSink(makeAddr("otherRouter"));
        vm.prank(admin);
        vm.expectRevert("wrong payment router");
        router.setReputationStorage(address(wrongRouter));
    }

    function test_commissionZeroBps() public {
        vm.prank(admin);
        router.setCommissionBps(0);

        uint256 paymentId = _settle(100e6, keccak256("ref-c0"));
        assertEq(usdc.balanceOf(provider), 100e6);
        assertFalse(router.getPayment(paymentId).reputationEligible, "zero-fee payments are not reputation");
    }

    function test_setCommissionBps() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit CommissionUpdated(500, 1000);
        vm.prank(admin);
        router.setCommissionBps(1000);
        assertEq(router.commissionBps(), 1000);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        _settle(100e6, keccak256("ref-1000"));
        assertEq(usdc.balanceOf(provider), 90e6);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 10e6);
    }

    function test_setCommissionTooHighReverts() public {
        vm.prank(admin);
        vm.expectRevert("commission too high");
        router.setCommissionBps(10001);
    }

    // L-1: admin sweep for tokens accidentally sent to the router.
    function test_rescueERC20_nonAcceptedToken() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(router), 123e6);

        address recipient = makeAddr("rescueRecipient");
        vm.prank(admin);
        router.rescueERC20(stray, recipient, 123e6);
        assertEq(stray.balanceOf(recipient), 123e6);
        assertEq(stray.balanceOf(address(router)), 0);
    }

    function test_rescueERC20_acceptedTokenReverts() public {
        // Accepted token rescue is forbidden — admin must temporarily de-list
        // first. This is the explicit defense-in-depth mentioned in the
        // contract NatSpec.
        usdc.mint(address(router), 50e6);
        vm.prank(admin);
        vm.expectRevert("accepted token");
        router.rescueERC20(usdc, makeAddr("anywhere"), 50e6);

        // Unlist → rescue → re-list flow works.
        vm.prank(admin);
        router.setAcceptedToken(address(usdc), false);
        address recipient = makeAddr("rescueRecipient");
        vm.prank(admin);
        router.rescueERC20(usdc, recipient, 50e6);
        assertEq(usdc.balanceOf(recipient), 50e6);
        vm.prank(admin);
        router.setAcceptedToken(address(usdc), true);
    }

    function test_rescueERC20_zeroToReverts() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(router), 1);
        vm.prank(admin);
        vm.expectRevert("zero to");
        router.rescueERC20(stray, address(0), 1);
    }

    function test_rescueERC20_onlyAdmin() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(router), 1);
        vm.prank(buyer);
        vm.expectRevert("not admin");
        router.rescueERC20(stray, buyer, 1);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(true, true, true, true, address(router));
        emit TreasuryUpdated(treasury, newTreasury);
        vm.prank(admin);
        router.setTreasury(newTreasury);
        assertEq(router.treasury(), newTreasury);
    }

    function test_nonAdminCannotSetCommission() public {
        vm.prank(buyer);
        vm.expectRevert("not admin");
        router.setCommissionBps(100);
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        // Step 1 — propose. Admin still has authority until acceptance.
        vm.prank(admin);
        router.transferAdmin(newAdmin);
        assertEq(router.pendingAdmin(), newAdmin);
        assertEq(router.admin(), admin, "admin unchanged before acceptance");

        // Until newAdmin accepts, only the old admin holds authority.
        vm.prank(newAdmin);
        vm.expectRevert("not admin");
        router.setCommissionBps(50);

        // Random address cannot accept.
        vm.prank(makeAddr("random"));
        vm.expectRevert("not pending admin");
        router.acceptAdmin();

        // Step 2 — accept from the proposed key.
        vm.prank(newAdmin);
        router.acceptAdmin();
        assertEq(router.admin(), newAdmin);
        assertEq(router.pendingAdmin(), address(0));

        vm.prank(admin);
        vm.expectRevert("not admin");
        router.setCommissionBps(100);

        vm.prank(newAdmin);
        router.setCommissionBps(100);
        assertEq(router.commissionBps(), 100);
    }

    function test_transferAdminZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert("zero admin");
        router.transferAdmin(address(0));
    }

    // ── Views ────────────────────────────────────────────────────────

    function test_quoteCommission() public view {
        (uint256 commission, uint256 providerAmount) = router.quoteCommission(100e6);
        assertEq(commission, 5e6);
        assertEq(providerAmount, 95e6);
    }

    function test_getPaymentNonExistentReverts() public {
        vm.expectRevert("payment not found");
        router.getPayment(999);
    }

    // ── Multi-token ──────────────────────────────────────────────────

    function test_multipleTokens() public {
        MockUSDC token2 = new MockUSDC();
        vm.prank(admin);
        router.setAcceptedToken(address(token2), true);

        token2.mint(buyer, 200e6);

        _settle(50e6, keccak256("ref-t1"));

        vm.prank(buyer);
        token2.approve(address(adapter), 80e6);
        vm.prank(buyer);
        uint256 paymentId2 =
            adapter.settle(address(token2), 80e6, keccak256("ref-t2"), buyerAgentId, buyer, providerAgentId, serviceId);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId2);
        assertEq(rec.token, address(token2));
        assertEq(rec.amount, 80e6);
        assertEq(token2.balanceOf(provider), 76e6);
    }

    function invariant_settlementConservesFundsAndLeavesNoCustody() public view {
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(
            usdc.balanceOf(provider) + usdc.balanceOf(treasury),
            invariantRecipientBalanceBefore + handler.totalSettled()
        );
    }
}
