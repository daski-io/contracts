// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";

contract ProviderRegistryTest is Test {
    MockCanonicalIdentityRegistry identity;
    ProviderRegistry registry;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address otherUser = makeAddr("otherUser");
    address operator = makeAddr("operator");

    uint256 constant LISTING_FEE = 1_000_000;
    string constant AGENT_URI = "https://example.com/agent.json";

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

    /// @dev `register` stays strict on `ownerOf` even after the auth-model
    ///      broadening — listing is a one-time act of consent that should
    ///      require the actual NFT key, not a delegate.
    function test_register_byOperator_reverts() public {
        vm.prank(provider);
        uint256 agentId = identity.register(AGENT_URI);

        vm.prank(provider);
        identity.setApprovalForAll(operator, true);

        usdc.mint(operator, LISTING_FEE);
        vm.prank(operator);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(operator);
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

    function test_setActive_byApprovedForAllOperator() public {
        uint256 agentId = _registerAsProvider(provider);

        vm.prank(provider);
        identity.setApprovalForAll(operator, true);

        vm.prank(operator);
        registry.setActive(agentId, false);
        assertFalse(registry.getProvider(agentId).isActive);
    }

    function test_setActive_byPerTokenApprovedSpender() public {
        uint256 agentId = _registerAsProvider(provider);

        vm.prank(provider);
        identity.approve(operator, agentId);

        vm.prank(operator);
        registry.setActive(agentId, false);
        assertFalse(registry.getProvider(agentId).isActive);
    }

    function test_setActiveByStrangerReverts() public {
        uint256 agentId = _registerAsProvider(provider);
        vm.prank(otherUser);
        vm.expectRevert("not owner or operator");
        registry.setActive(agentId, false);
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

        // Sentinel-size limit with a nonzero offset clamps to the tail
        // instead of overflowing offset+limit.
        uint256[] memory sentinel = registry.getProviderIdsPaginated(1, type(uint256).max);
        assertEq(sentinel.length, 4);
        assertEq(sentinel[0], ids[1]);
    }
}
