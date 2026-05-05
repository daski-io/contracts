// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {PermitAdapter} from "../src/adapters/PermitAdapter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IPermitAdapter} from "../src/interfaces/IPermitAdapter.sol";
import {PermitSigner} from "./helpers/PermitSigner.sol";

contract PermitAdapterTest is Test {
    IdentityRegistry identity;
    ProviderRegistry registry;
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

        PermitAdapter aImpl = new PermitAdapter();
        adapter = PermitAdapter(
            address(
                new ERC1967Proxy(
                    address(aImpl),
                    abi.encodeCall(PermitAdapter.initialize, (address(router), address(identity), admin))
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
        IPermitAdapter.PermitData memory p = PermitSigner.signPermit(
            vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp + 1 hours
        );
        vm.prank(buyer);
        uint256 paymentId = adapter.settle(address(usdc), 100e6, keccak256("p-ref"), providerAgentId, p);

        assertEq(usdc.balanceOf(provider), 95e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        IPaymentRouter.PaymentRecord memory rec = router.getPayment(paymentId);
        assertEq(rec.amount, 100e6);
        assertEq(rec.token, address(usdc));
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
        adapter.settle(address(usdc), 100e6, keccak256("p-bad"), providerAgentId, p);
    }

    function test_settleExpiredDeadlineWithoutAllowanceReverts() public {
        IPermitAdapter.PermitData memory p =
            PermitSigner.signPermit(vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp - 1);
        // Expired permit throws inside try/catch → swallowed → transferFrom
        // then reverts because allowance was never granted.
        vm.prank(buyer);
        vm.expectRevert();
        adapter.settle(address(usdc), 100e6, keccak256("p-exp"), providerAgentId, p);
    }

    function test_settleWithPreExistingAllowanceSkipsPermit() public {
        // If the buyer already approved the adapter, a stale/broken permit
        // should still succeed (try/catch pattern).
        vm.prank(buyer);
        usdc.approve(address(adapter), 100e6);

        IPermitAdapter.PermitData memory p =
            PermitSigner.signPermit(vm, BUYER_KEY, address(usdc), buyer, address(adapter), 100e6, block.timestamp - 1);
        vm.prank(buyer);
        adapter.settle(address(usdc), 100e6, keccak256("p-pre"), providerAgentId, p);
        assertEq(usdc.balanceOf(provider), 95e6);
    }

    function test_settleUnacceptedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        IPermitAdapter.PermitData memory p = PermitSigner.signPermit(
            vm, BUYER_KEY, address(other), buyer, address(adapter), 100e6, block.timestamp + 1 hours
        );
        vm.prank(buyer);
        vm.expectRevert("token not accepted");
        adapter.settle(address(other), 100e6, keccak256("p-unk"), providerAgentId, p);
    }
}
