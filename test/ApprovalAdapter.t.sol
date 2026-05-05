// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ApprovalAdapter} from "../src/adapters/ApprovalAdapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";

contract ApprovalAdapterTest is Test {
    IdentityRegistry identity;
    ProviderRegistry registry;
    PaymentRouter router;
    ApprovalAdapter adapter;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address buyer = makeAddr("buyer");

    uint256 buyerAgentId;
    uint256 providerAgentId;

    function setUp() public {
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

        ApprovalAdapter aImpl = new ApprovalAdapter();
        adapter = ApprovalAdapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(ApprovalAdapter.initialize, (address(router), address(identity), admin))
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

    function test_settleHappyPath() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, keccak256("a-ref"), providerAgentId);

        assertEq(usdc.balanceOf(provider), 95e6);
        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.buyerAgentId, buyerAgentId);
    }

    function test_settleInsufficientAllowanceReverts() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 50e6);
        vm.prank(buyer);
        vm.expectRevert();
        adapter.settle(address(usdc), 100e6, keccak256("a-noall"), providerAgentId);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(buyer, 100e6);
        vm.prank(buyer);
        other.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(other), 100e6, keccak256("a-unk"), providerAgentId);
    }

    function test_settleBuyerNoAgentReverts() public {
        // Unregister buyer's wallet
        vm.prank(buyer);
        identity.unsetAgentWallet(buyerAgentId);

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("buyer has no agent");
        adapter.settle(address(usdc), 100e6, keccak256("a-noid"), providerAgentId);
    }
}
