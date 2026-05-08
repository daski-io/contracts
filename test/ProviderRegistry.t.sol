// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";

contract ProviderRegistryTest is Test {
    IdentityRegistry identity;
    ProviderRegistry registry;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address otherUser = makeAddr("otherUser");

    uint256 constant LISTING_FEE = 1_000_000;
    string constant AGENT_URI = "https://example.com/agent.json";

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
                        ProviderRegistry.initialize, (address(identity), address(usdc), treasury, LISTING_FEE, admin)
                    )
                )
            )
        );

        usdc.mint(provider, 100_000_000);
        vm.prank(provider);
        usdc.approve(address(registry), type(uint256).max);
    }

    function _registerAsProvider(address who) internal returns (uint256 agentId) {
        vm.prank(who);
        agentId = identity.register(AGENT_URI);
        usdc.mint(who, LISTING_FEE);
        vm.prank(who);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(who);
        registry.register(agentId);
    }

    function test_registerHappyPath() public {
        vm.prank(provider);
        uint256 agentId = identity.register(AGENT_URI);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(provider);
        registry.register(agentId);

        IProviderRegistry.Provider memory p = registry.getProvider(agentId);
        assertEq(p.walletAddress, provider);
        assertEq(p.agentId, agentId);
        assertEq(p.registrationTime, block.timestamp);
        assertTrue(p.isActive);

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, LISTING_FEE);
        assertTrue(registry.isRegistered(agentId));
    }

    function test_registerEmitsEvent() public {
        vm.prank(provider);
        uint256 agentId = identity.register(AGENT_URI);

        vm.expectEmit(true, true, false, false, address(registry));
        emit ProviderRegistry.ProviderRegistered(agentId, provider);

        vm.prank(provider);
        registry.register(agentId);
    }

    function test_registerWithoutIdentityReverts() public {
        // otherUser has no ERC-8004 agent.
        usdc.mint(otherUser, LISTING_FEE);
        vm.prank(otherUser);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(otherUser);
        vm.expectRevert(); // ERC721NonexistentToken
        registry.register(1);
    }

    function test_registerByNonOwnerReverts() public {
        vm.prank(provider);
        uint256 agentId = identity.register(AGENT_URI);

        vm.prank(otherUser);
        usdc.mint(otherUser, LISTING_FEE);
        vm.prank(otherUser);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(otherUser);
        vm.expectRevert("not agent owner");
        registry.register(agentId);
    }

    function test_registerDuplicateReverts() public {
        uint256 agentId = _registerAsProvider(provider);
        vm.prank(provider);
        vm.expectRevert("already registered");
        registry.register(agentId);
    }

    function test_registerWithoutApprovalReverts() public {
        vm.prank(otherUser);
        uint256 agentId = identity.register(AGENT_URI);
        usdc.mint(otherUser, LISTING_FEE);
        vm.prank(otherUser);
        vm.expectRevert();
        registry.register(agentId);
    }

    function test_updateWalletAddress() public {
        uint256 agentId = _registerAsProvider(provider);
        address newWallet = makeAddr("newWallet");

        vm.expectEmit(true, true, false, false, address(registry));
        emit ProviderRegistry.ProviderWalletUpdated(agentId, newWallet);
        vm.prank(provider);
        registry.updateWalletAddress(agentId, newWallet);

        IProviderRegistry.Provider memory p = registry.getProvider(agentId);
        assertEq(p.walletAddress, newWallet);
    }

    function test_updateWalletAddressByStrangerReverts() public {
        uint256 agentId = _registerAsProvider(provider);
        vm.prank(otherUser);
        vm.expectRevert("not agent owner");
        registry.updateWalletAddress(agentId, otherUser);
    }

    // M-4: zero address must be rejected. Without this guard, the provider
    // could route their own payments to the burn address and lose funds.
    function test_updateWalletAddressZeroReverts() public {
        uint256 agentId = _registerAsProvider(provider);
        vm.prank(provider);
        vm.expectRevert("zero wallet");
        registry.updateWalletAddress(agentId, address(0));
    }

    function test_setTreasuryZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert("zero treasury");
        registry.setTreasury(address(0));
    }

    function test_setActive() public {
        uint256 agentId = _registerAsProvider(provider);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderRegistry.ProviderActiveStatusChanged(agentId, false);
        vm.prank(provider);
        registry.setActive(agentId, false);

        assertFalse(registry.getProvider(agentId).isActive);

        vm.prank(provider);
        registry.setActive(agentId, true);
        assertTrue(registry.getProvider(agentId).isActive);
    }

    function test_getProviderByAddress() public {
        uint256 agentId = _registerAsProvider(provider);
        IProviderRegistry.Provider memory p = registry.getProviderByAddress(provider);
        assertEq(p.walletAddress, provider);
        assertEq(p.agentId, agentId);
    }

    function test_getProviderCount() public {
        assertEq(registry.getProviderCount(), 0);
        _registerAsProvider(provider);
        assertEq(registry.getProviderCount(), 1);
        _registerAsProvider(otherUser);
        assertEq(registry.getProviderCount(), 2);
    }

    function test_setListingFee() public {
        uint256 newFee = 5_000_000;
        vm.expectEmit(false, false, false, true, address(registry));
        emit ProviderRegistry.ListingFeeUpdated(LISTING_FEE, newFee);
        vm.prank(admin);
        registry.setListingFee(newFee);
        assertEq(registry.listingFee(), newFee);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(false, false, false, true, address(registry));
        emit ProviderRegistry.TreasuryUpdated(treasury, newTreasury);
        vm.prank(admin);
        registry.setTreasury(newTreasury);
        assertEq(registry.treasury(), newTreasury);
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        registry.transferAdmin(newAdmin);
        assertEq(registry.pendingAdmin(), newAdmin);
        assertEq(registry.admin(), admin, "admin unchanged before acceptance");

        vm.prank(makeAddr("random"));
        vm.expectRevert("not pending admin");
        registry.acceptAdmin();

        vm.prank(newAdmin);
        registry.acceptAdmin();
        assertEq(registry.admin(), newAdmin);
        assertEq(registry.pendingAdmin(), address(0));

        vm.prank(admin);
        vm.expectRevert("not admin");
        registry.setListingFee(0);

        vm.prank(newAdmin);
        registry.setListingFee(0);
        assertEq(registry.listingFee(), 0);
    }

    function test_nonAdminCannotSetFee() public {
        vm.prank(otherUser);
        vm.expectRevert("not admin");
        registry.setListingFee(0);
    }

    // L-2: paginated providerIds view.
    function test_getProviderIdsPaginated() public {
        // Seed five providers (each with their own agent).
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            address who = makeAddr(string.concat("p", vm.toString(i)));
            ids[i] = _registerAsProvider(who);
        }
        assertEq(registry.getProviderCount(), 5);

        uint256[] memory page = registry.getProviderIdsPaginated(1, 3);
        assertEq(page.length, 3);
        assertEq(page[0], ids[1]);
        assertEq(page[1], ids[2]);
        assertEq(page[2], ids[3]);

        // Limit > remaining clamps.
        uint256[] memory tail = registry.getProviderIdsPaginated(4, 100);
        assertEq(tail.length, 1);
        assertEq(tail[0], ids[4]);

        // Offset past end → empty.
        uint256[] memory past = registry.getProviderIdsPaginated(5, 1);
        assertEq(past.length, 0);
    }
}
