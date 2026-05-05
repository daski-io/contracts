// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IX402Adapter} from "../src/interfaces/IX402Adapter.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";

contract X402AdapterTest is Test {
    IdentityRegistry identity;
    ProviderRegistry registry;
    PaymentRouter router;
    X402Adapter adapter;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address relayer = makeAddr("relayer");
    address provider = makeAddr("provider");

    uint256 constant BUYER_KEY = 0xA11CE;
    address buyer;
    uint256 buyerAgentId;
    uint256 providerAgentId;

    function setUp() public {
        buyer = vm.addr(BUYER_KEY);
        usdc = new MockUSDC();

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

        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example.com/agent.json");
        usdc.mint(provider, 1_000_000);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1_000_000);
        registry.register(providerAgentId);
        vm.stopPrank();

        vm.prank(buyer);
        buyerAgentId = identity.register();
        usdc.mint(buyer, 1000e6);
    }

    function _authFor(uint256 value, bytes32 nonce) internal view returns (IX402Adapter.EIP3009Auth memory) {
        return EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(usdc), buyer, address(router), value, 0, block.timestamp + 1 hours, nonce
        );
    }

    function test_settleHappyPath() public {
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, keccak256("n-1"));
        vm.prank(relayer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, keccak256("ref-1"), providerAgentId, auth);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(treasury), 6e6); // includes 1 USDC listing fee from setUp
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(rec.providerAgentId, providerAgentId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.token, address(usdc));
    }

    function test_settleBadSignatureReverts() public {
        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, keccak256("n-2"));
        auth.v = auth.v == 27 ? 28 : 27;
        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settle(address(usdc), 100e6, keccak256("ref"), providerAgentId, auth);
    }

    function test_settleExpiredAuthReverts() public {
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(usdc), buyer, address(router), 100e6, 0, block.timestamp + 10, keccak256("n-3")
        );
        vm.warp(block.timestamp + 100);
        vm.prank(relayer);
        vm.expectRevert("auth expired");
        adapter.settle(address(usdc), 100e6, keccak256("ref"), providerAgentId, auth);
    }

    function test_settleNonceReplayReverts() public {
        bytes32 nonce = keccak256("n-reuse");
        IX402Adapter.EIP3009Auth memory auth = _authFor(50e6, nonce);
        vm.prank(relayer);
        adapter.settle(address(usdc), 50e6, keccak256("r1"), providerAgentId, auth);

        vm.prank(relayer);
        vm.expectRevert("auth already used");
        adapter.settle(address(usdc), 50e6, keccak256("r2"), providerAgentId, auth);
    }

    function test_settleBuyerNoAgentReverts() public {
        // Buyer rotates wallet (i.e. unsets), so agentOfWallet returns 0.
        vm.prank(buyer);
        identity.unsetAgentWallet(buyerAgentId);

        IX402Adapter.EIP3009Auth memory auth = _authFor(100e6, keccak256("n-4"));
        vm.prank(relayer);
        vm.expectRevert("buyer has no agent");
        adapter.settle(address(usdc), 100e6, keccak256("ref"), providerAgentId, auth);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(buyer, 100e6);
        IX402Adapter.EIP3009Auth memory auth = EIP3009Signer.signTransfer(
            vm, BUYER_KEY, address(other), buyer, address(router), 100e6, 0, block.timestamp + 1 hours, keccak256("n-5")
        );
        vm.prank(relayer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(other), 100e6, keccak256("ref"), providerAgentId, auth);
    }

    // --- settleWithRegistration (atomic gasless register-and-settle) -----

    uint256 constant FRESH_BUYER_KEY = 0xDA571;

    function _signRegisterAgent(uint256 key, address agentWallet, string memory uri, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typehash = identity.REGISTER_AGENT_TYPEHASH();
        bytes32 structHash = keccak256(abi.encode(typehash, keccak256(bytes(uri)), agentWallet, nonce, deadline));
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Daski IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(identity)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _eip3009For(uint256 key, address from, uint256 value, bytes32 nonce)
        internal
        view
        returns (IX402Adapter.EIP3009Auth memory)
    {
        return EIP3009Signer.signTransfer(
            vm, key, address(usdc), from, address(router), value, 0, block.timestamp + 1 hours, nonce
        );
    }

    function test_settleWithRegistration_unregisteredBuyer() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);

        // No agent yet for freshBuyer.
        assertEq(identity.agentOfWallet(freshBuyer), 0, "precondition: not registered");

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory regSig = _signRegisterAgent(FRESH_BUYER_KEY, freshBuyer, "ipfs://fresh", 0, deadline);
        IX402Adapter.EIP3009Auth memory auth = _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, keccak256("swr-1"));

        vm.prank(relayer);
        (uint256 newBuyerAgentId, uint256 paymentId) = adapter.settleWithRegistration(
            address(usdc), 80e6, keccak256("ref-swr-1"), providerAgentId, auth, "ipfs://fresh", deadline, regSig
        );

        // Registered + paid in one tx.
        assertGt(newBuyerAgentId, 0, "buyer registered");
        assertEq(identity.ownerOf(newBuyerAgentId), freshBuyer);
        assertEq(identity.agentOfWallet(freshBuyer), newBuyerAgentId);

        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, newBuyerAgentId);
        assertEq(rec.amount, 80e6);
    }

    function test_settleWithRegistration_alreadyRegisteredSkipsRegistration() public {
        // Existing buyer (from setUp) is already registered with agentId=2.
        // The registration sig + agentURI args should be ignored and the
        // original agentId reused.
        uint256 deadline = block.timestamp + 1 hours;
        // Deliberately pass a signature that would FAIL if checked — proves
        // the contract takes the short-circuit path when already registered.
        bytes memory invalidRegSig = hex"deadbeef";
        IX402Adapter.EIP3009Auth memory auth = _authFor(50e6, keccak256("swr-2"));

        vm.prank(relayer);
        (uint256 reusedAgentId, uint256 paymentId) = adapter.settleWithRegistration(
            address(usdc), 50e6, keccak256("ref-swr-2"), providerAgentId, auth, "anything", deadline, invalidRegSig
        );

        assertEq(reusedAgentId, buyerAgentId, "existing agentId reused");
        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.buyerAgentId, buyerAgentId);
    }

    function test_settleWithRegistration_atomicRevertOnBadRegistration() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign registration with the WRONG key — registration will revert.
        bytes memory badRegSig = _signRegisterAgent(0xBAD, freshBuyer, "ipfs://x", 0, deadline);
        IX402Adapter.EIP3009Auth memory auth = _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, keccak256("swr-3"));

        uint256 freshBuyerUsdcBefore = usdc.balanceOf(freshBuyer);

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settleWithRegistration(
            address(usdc), 80e6, keccak256("ref-swr-3"), providerAgentId, auth, "ipfs://x", deadline, badRegSig
        );

        // Atomicity: nothing moved.
        assertEq(identity.agentOfWallet(freshBuyer), 0, "no agent minted");
        assertEq(usdc.balanceOf(freshBuyer), freshBuyerUsdcBefore, "no USDC moved");
    }

    function test_settleWithRegistration_atomicRevertOnBadSettlement() public {
        address freshBuyer = vm.addr(FRESH_BUYER_KEY);
        usdc.mint(freshBuyer, 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory regSig = _signRegisterAgent(FRESH_BUYER_KEY, freshBuyer, "ipfs://x", 0, deadline);
        IX402Adapter.EIP3009Auth memory auth = _eip3009For(FRESH_BUYER_KEY, freshBuyer, 80e6, keccak256("swr-4"));
        // Corrupt the EIP-3009 signature so settlement reverts AFTER
        // registration succeeded inside the same call frame.
        auth.v = auth.v == 27 ? 28 : 27;

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        adapter.settleWithRegistration(
            address(usdc), 80e6, keccak256("ref-swr-4"), providerAgentId, auth, "ipfs://x", deadline, regSig
        );

        // Atomicity: registration is rolled back along with the failed transfer.
        assertEq(identity.agentOfWallet(freshBuyer), 0, "registration rolled back");
        assertEq(identity.registrationNonce(freshBuyer), 0, "nonce rolled back");
    }
}
