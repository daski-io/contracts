// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {PermitAdapter} from "../src/adapters/PermitAdapter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IPermitAdapter} from "../src/interfaces/IPermitAdapter.sol";
import {PermitSigner} from "./helpers/PermitSigner.sol";
import {MockReputationSink} from "./helpers/MockReputationSink.sol";

contract PermitAdapterTest is Test {
    uint256 constant REPUTATION_MINIMUM = 250_000;

    MockCanonicalIdentityRegistry identity;
    AgentIndex agentIndex;
    ProviderRegistry registry;
    ServiceRegistry services;
    PaymentRouter router;
    PermitAdapter adapter;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");

    uint256 constant BUYER_KEY = 0xB0B;
    address buyer;
    uint256 buyerAgentId;
    uint256 providerAgentId;
    bytes32 serviceId;

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

        PermitAdapter aImpl = new PermitAdapter();
        adapter = PermitAdapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(PermitAdapter.initialize, (address(router), address(agentIndex), admin))
                )
            )
        );

        MockReputationSink sink = new MockReputationSink(address(router));
        vm.prank(admin);
        router.setReputationStorage(address(sink));
        vm.prank(admin);
        router.setAdapter(address(adapter), true);
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

    function test_settleHappyPath() public {
        IPermitAdapter.PermitData memory p = PermitSigner.signPermit(
            vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp + 1 hours
        );
        vm.prank(buyer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, keccak256("p-ref"), providerAgentId, serviceId, p);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.token, address(usdc));
        assertEq(rec.serviceId, serviceId);
    }

    function test_settleBadPermitWithoutAllowanceReverts() public {
        // Generate a permit with a tampered signature. try/catch swallows
        // the permit failure, but the subsequent transferFrom reverts for
        // lack of allowance.
        IPermitAdapter.PermitData memory p = PermitSigner.signPermit(
            vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp + 1 hours
        );
        p.v = p.v == 27 ? 28 : 27;

        vm.prank(buyer);
        vm.expectRevert(); // SafeERC20 wraps; OZ ERC20 reverts on insufficient allowance
        adapter.settle(address(usdc), 100e6, keccak256("p-bad"), providerAgentId, serviceId, p);
    }

    function test_settleExpiredDeadlineWithoutAllowanceReverts() public {
        IPermitAdapter.PermitData memory p =
            PermitSigner.signPermit(vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp - 1);
        // Expired permit throws inside try/catch → swallowed → transferFrom
        // then reverts because allowance was never granted.
        vm.prank(buyer);
        vm.expectRevert();
        adapter.settle(address(usdc), 100e6, keccak256("p-exp"), providerAgentId, serviceId, p);
    }

    function test_settleWithPreExistingAllowanceSkipsPermit() public {
        // If the buyer already approved the adapter, a stale/broken permit
        // should still succeed (try/catch pattern).
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);

        IPermitAdapter.PermitData memory p =
            PermitSigner.signPermit(vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp - 1);
        vm.prank(buyer);
        adapter.settle(address(usdc), 100e6, keccak256("p-pre"), providerAgentId, serviceId, p);
        assertEq(usdc.balanceOf(provider), 95e6);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        IPermitAdapter.PermitData memory p = PermitSigner.signPermit(
            vm, BUYER_KEY, address(other), buyer, address(adapter), 100e6, block.timestamp + 1 hours
        );
        vm.prank(buyer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(other), 100e6, keccak256("p-unk"), providerAgentId, serviceId, p);
    }

    function test_settleFeeOnTransferTokenRevertsAtomicallyWithAllowance() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(buyer, 100e6);
        vm.prank(admin);
        router.setAcceptedToken(address(feeToken), true);
        vm.prank(buyer);
        feeToken.approve(address(adapter), 100e6);

        IPermitAdapter.PermitData memory unsupportedPermit = IPermitAdapter.PermitData({
            value: 100e6, deadline: block.timestamp + 1 hours, v: 27, r: bytes32(0), s: bytes32(0)
        });
        vm.prank(buyer);
        vm.expectRevert("unexpected token amount");
        adapter.settle(address(feeToken), 100e6, keccak256("p-fee"), providerAgentId, serviceId, unsupportedPermit);

        assertEq(feeToken.balanceOf(buyer), 100e6);
        assertEq(feeToken.balanceOf(address(router)), 0);
        assertEq(router.nextPaymentId(), 1);
    }
}
