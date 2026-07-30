// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {IPaymentRouter} from "../../src/interfaces/IPaymentRouter.sol";
import {IX402Adapter} from "../../src/interfaces/IX402Adapter.sol";
import {X402CircleForkFixture} from "../helpers/X402CircleForkFixture.sol";

contract X402CircleForkTest is X402CircleForkFixture {
    uint256 private constant MAINNET_BLOCK = 49_316_000;
    bytes32 private constant MAINNET_BLOCK_HASH = 0x12dc1218fc226c8a2521ff2f7349c461a01189476e389fb24ab5d994f1155f32;
    address private constant MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes32 private constant MAINNET_DOMAIN = 0x02fa7265e7c5d81118673727957699e4d68f74cd74b7db77da710fe8a2c7834f;

    uint256 private constant SEPOLIA_BLOCK = 44_827_000;
    bytes32 private constant SEPOLIA_BLOCK_HASH = 0xc3c39329b0aa5b0eec61dc2d6933c3e05e7c1dd6de888622a25639731dd38dd5;
    address private constant SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes32 private constant SEPOLIA_DOMAIN = 0x71f17a3b2ff373b803d70a5a07c046c1a2bc8e89c09ef722fcb047abe94c9818;

    function test_baseMainnetCircleReceivePaths() public {
        _createForkAndStack(
            vm.envString("BASE_MAINNET_RPC_URL"),
            MAINNET_BLOCK,
            MAINNET_BLOCK_HASH,
            8453,
            MAINNET_USDC,
            "USD Coin",
            MAINNET_DOMAIN
        );
        _exerciseExistingBuyers("USDC", 84532);
        _exerciseAtomicRegistration();
    }

    function test_baseSepoliaCircleReceivePaths() public {
        _createForkAndStack(
            vm.envString("BASE_SEPOLIA_RPC_URL"),
            SEPOLIA_BLOCK,
            SEPOLIA_BLOCK_HASH,
            84532,
            SEPOLIA_USDC,
            "USDC",
            SEPOLIA_DOMAIN
        );
        _exerciseExistingBuyers("USD Coin", 8453);
    }

    function _exerciseExistingBuyers(string memory wrongName, uint256 wrongChainId) private {
        uint256 buyerKey = 0xA11CE;
        address buyer = vm.addr(buyerKey);
        uint256 buyerAgentId = _registerBuyer(buyer);
        _seed(buyer, 300e6);

        bytes32 serviceRef = keccak256("fork-eoa");
        bytes32 salt = keccak256("fork-eoa-salt");
        IX402Adapter.EIP3009Auth memory auth = _auth(buyerKey, buyer, 100e6, serviceRef, salt, usdcName, block.chainid);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(facilitator);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, serviceRef, providerAgentId, serviceId, auth, salt);
        _assertPayment(paymentId, buyerAgentId, serviceRef, providerBefore, treasuryBefore);
        assertTrue(usdc.authorizationState(buyer, auth.nonce), "authorization unused");

        vm.prank(facilitator);
        vm.expectRevert();
        adapter.settle(address(usdc), 100e6, serviceRef, providerAgentId, serviceId, auth, salt);
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter retained replay funds");
        assertEq(usdc.balanceOf(address(router)), 0, "router retained replay funds");

        bytes32 wrongRef = keccak256("fork-wrong-domain");
        bytes32 wrongSalt = keccak256("fork-wrong-domain-salt");
        IX402Adapter.EIP3009Auth memory wrongAuth =
            _auth(buyerKey, buyer, 50e6, wrongRef, wrongSalt, wrongName, wrongChainId);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(facilitator);
        vm.expectRevert();
        adapter.settle(address(usdc), 50e6, wrongRef, providerAgentId, serviceId, wrongAuth, wrongSalt);
        assertFalse(usdc.authorizationState(buyer, wrongAuth.nonce), "wrong domain consumed nonce");
        assertEq(usdc.balanceOf(buyer), buyerBefore, "wrong domain moved funds");

        uint256 walletOwnerKey = 0xB0B;
        MockERC1271Wallet wallet = new MockERC1271Wallet(vm.addr(walletOwnerKey));
        uint256 walletAgentId = _registerBuyer(address(wallet));
        _seed(address(wallet), 100e6);
        bytes32 walletRef = keccak256("fork-1271");
        bytes32 walletSalt = keccak256("fork-1271-salt");
        IX402Adapter.EIP3009Auth memory walletAuth =
            _auth(walletOwnerKey, address(wallet), 80e6, walletRef, walletSalt, usdcName, block.chainid);
        providerBefore = usdc.balanceOf(provider);
        treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(facilitator);
        paymentId = adapter.settle(address(usdc), 80e6, walletRef, providerAgentId, serviceId, walletAuth, walletSalt);
        _assertPayment(paymentId, walletAgentId, walletRef, providerBefore, treasuryBefore);
    }

    function _exerciseAtomicRegistration() private {
        uint256 buyerKey = 0xDA571;
        address buyer = vm.addr(buyerKey);
        _seed(buyer, 100e6);
        bytes32 serviceRef = keccak256("fork-registration");
        bytes32 salt = keccak256(abi.encode("fork-registration-salt", buyer));
        uint256 deadline = block.timestamp + 1 hours;
        IX402Adapter.EIP3009Auth memory auth = _auth(buyerKey, buyer, 80e6, serviceRef, salt, usdcName, block.chainid);
        bytes memory registration = _registrationSignature(buyerKey, "ipfs://fork-buyer", deadline);

        vm.prank(facilitator);
        (uint256 buyerAgentId, uint256 paymentId) = adapter.settleWithRegistration(
            address(usdc),
            80e6,
            serviceRef,
            providerAgentId,
            serviceId,
            auth,
            salt,
            "ipfs://fork-buyer",
            deadline,
            registration
        );
        assertEq(identity.ownerOf(buyerAgentId), buyer, "registration owner");
        IPaymentRouter.PaymentRecord memory record = router.getPayment(paymentId);
        assertEq(record.buyerAgentId, buyerAgentId, "registration payment buyer");
        assertTrue(usdc.authorizationState(buyer, auth.nonce), "registration nonce unused");
    }

    function _assertPayment(
        uint256 paymentId,
        uint256 buyerAgentId,
        bytes32 serviceRef,
        uint256 providerBefore,
        uint256 treasuryBefore
    ) private view {
        IPaymentRouter.PaymentRecord memory record = router.getPayment(paymentId);
        assertEq(record.buyerAgentId, buyerAgentId, "payment buyer");
        assertEq(record.providerAgentId, providerAgentId, "payment provider");
        assertEq(record.serviceId, serviceId, "payment service");
        assertEq(record.serviceRef, serviceRef, "payment reference");
        assertEq(usdc.balanceOf(provider), providerBefore + (record.amount * 9500) / 10_000, "provider split");
        assertEq(usdc.balanceOf(treasury), treasuryBefore + (record.amount * 500) / 10_000, "treasury split");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter retained funds");
        assertEq(usdc.balanceOf(address(router)), 0, "router retained funds");
    }
}
