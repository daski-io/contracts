// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ApprovalAdapter} from "../src/adapters/ApprovalAdapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";

contract ApprovalAdapterTest is Test {
    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    ProviderRegistry registry;
    ServiceRegistry services;
    PaymentRouter router;
    ApprovalAdapter adapter;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address buyer = makeAddr("buyer");

    uint256 buyerAgentId;
    uint256 providerAgentId;
    bytes32 serviceId;

    function setUp() public {
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

        ApprovalAdapter aImpl = new ApprovalAdapter();
        adapter = ApprovalAdapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(ApprovalAdapter.initialize, (address(router), address(agentIndex), admin))
                )
            )
        );

        vm.prank(admin);
        router.setAdapter(address(adapter), true);
        vm.prank(admin);
        router.setAcceptedToken(address(usdc), true);

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

    function test_settleHappyPath() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, keccak256("a-ref"), providerAgentId, serviceId);

        assertEq(usdc.balanceOf(provider), 95e6);
        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.buyerAgentId, buyerAgentId);
        assertEq(rec.serviceId, serviceId);
    }

    function test_settleInsufficientAllowanceReverts() public {
        vm.prank(buyer);
        usdc.approve(address(adapter), 50e6);
        vm.prank(buyer);
        vm.expectRevert();
        adapter.settle(address(usdc), 100e6, keccak256("a-noall"), providerAgentId, serviceId);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(buyer, 100e6);
        vm.prank(buyer);
        other.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(other), 100e6, keccak256("a-unk"), providerAgentId, serviceId);
    }

    function test_settleBuyerNoAgentReverts() public {
        // Buyer moves the agent NFT away — the AgentIndex binding goes stale
        // and resolve() returns 0.
        vm.prank(buyer);
        identity.transferFrom(buyer, makeAddr("elsewhere"), buyerAgentId);

        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);
        vm.prank(buyer);
        vm.expectRevert("buyer has no agent");
        adapter.settle(address(usdc), 100e6, keccak256("a-noid"), providerAgentId, serviceId);
    }
}
