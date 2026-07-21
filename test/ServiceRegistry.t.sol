// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {IServiceRegistry} from "../src/interfaces/IServiceRegistry.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";

contract ServiceRegistryTest is Test {
    MockCanonicalIdentityRegistry identity;
    ProviderRegistry providerRegistry;
    ServiceRegistry services;
    MockUSDC usdc;
    MockSanctionsList sanctions;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address operator = makeAddr("operator");
    address otherUser = makeAddr("otherUser");

    uint256 providerAgentId;

    function setUp() public {
        usdc = new MockUSDC();

        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();

        ProviderRegistry pregImpl = new ProviderRegistry();
        providerRegistry = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(pregImpl),
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
                        ServiceRegistry.initialize,
                        (address(identity), address(providerRegistry), address(sanctions), admin)
                    )
                )
            )
        );

        // Mint NFT + register as Daski provider.
        vm.prank(provider);
        providerAgentId = identity.register("https://provider.example/agent.json");
        usdc.mint(provider, 1_000_000);
        vm.startPrank(provider);
        usdc.approve(address(providerRegistry), 1_000_000);
        providerRegistry.register(providerAgentId);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _expectedId(uint256 agentId, string memory serviceSlug, string memory version)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(agentId, serviceSlug, version));
    }

    function _registerSimple(address as_, string memory serviceSlug, string memory version)
        internal
        returns (bytes32 serviceId)
    {
        vm.prank(as_);
        serviceId = services.registerService(providerAgentId, serviceSlug, version, "ipfs://meta", address(0));
    }

    // ── registerService ──────────────────────────────────────────────

    function test_registerService_byProviderOwner() public {
        bytes32 expected = _expectedId(providerAgentId, "domain-registration", "1");

        vm.expectEmit(true, true, false, true, address(services));
        emit IServiceRegistry.ServiceRegistered(
            expected, providerAgentId, "domain-registration", "1", "ipfs://meta", address(0)
        );

        bytes32 svcId = _registerSimple(provider, "domain-registration", "1");
        assertEq(svcId, expected);

        IServiceRegistry.Service memory svc = services.getService(svcId);
        assertEq(svc.providerAgentId, providerAgentId);
        assertEq(svc.serviceSlug, "domain-registration");
        assertEq(svc.version, "1");
        assertEq(svc.serviceURI, "ipfs://meta");
        assertEq(svc.serviceWallet, address(0));
        assertEq(svc.serviceWalletOwner, address(0));
        assertEq(svc.serviceWalletAgentWallet, address(0));
        assertTrue(svc.active);
        assertEq(svc.createdAt, uint64(block.timestamp));
    }

    function test_registerServiceSanctionedServiceWalletReverts() public {
        address serviceWallet = makeAddr("sanctionedServiceWallet");
        sanctions.setSanctioned(serviceWallet, true);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, serviceWallet));
        services.registerService(providerAgentId, "screened-wallet", "1", "ipfs://meta", serviceWallet);
    }

    function test_registerServiceOperatorCannotBypassSanctionedOwner() public {
        vm.prank(provider);
        identity.setApprovalForAll(operator, true);
        sanctions.setSanctioned(provider, true);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, provider));
        services.registerService(providerAgentId, "screened-owner", "1", "ipfs://meta", address(0));
    }

    function test_registerService_computeServiceIdMatches() public view {
        bytes32 expected = _expectedId(providerAgentId, "x", "v1");
        assertEq(services.computeServiceId(providerAgentId, "x", "v1"), expected);
    }

    function test_registerService_byNonOwnerReverts() public {
        vm.prank(otherUser);
        vm.expectRevert("not owner or operator");
        services.registerService(providerAgentId, "x", "1", "u", address(0));
    }

    function test_registerService_byOperator_isApprovedForAll() public {
        vm.prank(provider);
        identity.setApprovalForAll(operator, true);

        bytes32 svcId = _registerSimple(operator, "y", "1");
        assertEq(services.getService(svcId).providerAgentId, providerAgentId);
    }

    function test_registerService_byOperator_perTokenApprove() public {
        vm.prank(provider);
        identity.approve(operator, providerAgentId);

        bytes32 svcId = _registerSimple(operator, "z", "1");
        assertEq(services.getService(svcId).providerAgentId, providerAgentId);
    }

    function test_registerService_inactiveProviderReverts() public {
        vm.prank(provider);
        providerRegistry.setActive(providerAgentId, false);

        vm.prank(provider);
        vm.expectRevert("provider not active");
        services.registerService(providerAgentId, "skill", "1", "u", address(0));
    }

    function test_registerService_unregisteredProviderReverts() public {
        // Mint a fresh agent NFT but don't register it as a Daski provider.
        address freshOwner = makeAddr("freshOwner");
        vm.prank(freshOwner);
        uint256 freshAgent = identity.register("u");

        vm.prank(freshOwner);
        vm.expectRevert("provider not registered");
        services.registerService(freshAgent, "skill", "1", "u", address(0));
    }

    function test_registerService_duplicateReverts() public {
        _registerSimple(provider, "dup", "1");
        vm.prank(provider);
        vm.expectRevert("service already registered");
        services.registerService(providerAgentId, "dup", "1", "u2", address(0));
    }

    function test_registerService_differentVersion_distinctIds() public {
        bytes32 a = _registerSimple(provider, "skill", "1");
        bytes32 b = _registerSimple(provider, "skill", "2");
        assertTrue(a != b);
        assertEq(services.getServiceCountByProvider(providerAgentId), 2);
    }

    function test_registerService_emptySlugReverts() public {
        vm.prank(provider);
        vm.expectRevert("bad serviceSlug length");
        services.registerService(providerAgentId, "", "1", "u", address(0));
    }

    function test_registerService_slugTooLongReverts() public {
        // 65 chars
        string memory long65 = "12345678901234567890123456789012345678901234567890123456789012345";
        vm.prank(provider);
        vm.expectRevert("bad serviceSlug length");
        services.registerService(providerAgentId, long65, "1", "u", address(0));
    }

    function test_registerService_emptyVersionReverts() public {
        vm.prank(provider);
        vm.expectRevert("bad version length");
        services.registerService(providerAgentId, "skill", "", "u", address(0));
    }

    function test_registerService_versionTooLongReverts() public {
        // 33 chars
        string memory long33 = "123456789012345678901234567890123";
        vm.prank(provider);
        vm.expectRevert("bad version length");
        services.registerService(providerAgentId, "skill", long33, "u", address(0));
    }

    function test_registerService_distinctProvidersSameSlugVersion() public {
        // Two different providers register a service with the same
        // (serviceSlug, version) — the resulting serviceIds must differ
        // because providerAgentId is part of the hash.
        address otherProvider = makeAddr("otherProvider");
        vm.prank(otherProvider);
        uint256 otherAgentId = identity.register("u2");
        usdc.mint(otherProvider, 1_000_000);
        vm.startPrank(otherProvider);
        usdc.approve(address(providerRegistry), 1_000_000);
        providerRegistry.register(otherAgentId);
        vm.stopPrank();

        bytes32 a = _registerSimple(provider, "skill", "1");
        vm.prank(otherProvider);
        bytes32 b = services.registerService(otherAgentId, "skill", "1", "u", address(0));

        assertTrue(a != b);
    }

    // ── update / setActive / wallet ─────────────────────────────────

    function test_setServiceWallet_zeroIsClear() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");

        // Set non-zero
        address svcWallet = makeAddr("serviceWallet");
        vm.prank(provider);
        services.setServiceWallet(svcId, svcWallet);
        IServiceRegistry.Service memory authorized = services.getService(svcId);
        assertEq(authorized.serviceWallet, svcWallet);
        assertEq(authorized.serviceWalletOwner, provider);
        assertEq(authorized.serviceWalletAgentWallet, identity.getAgentWallet(providerAgentId));

        // Clear back to zero (signals "inherit provider's agentWallet")
        vm.prank(provider);
        services.setServiceWallet(svcId, address(0));
        IServiceRegistry.Service memory cleared = services.getService(svcId);
        assertEq(cleared.serviceWallet, address(0));
        assertEq(cleared.serviceWalletOwner, address(0));
        assertEq(cleared.serviceWalletAgentWallet, address(0));
    }

    function test_setServiceWallet_requiresLiveAgentWallet() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");
        vm.prank(provider);
        identity.unsetAgentWallet(providerAgentId);

        vm.prank(provider);
        vm.expectRevert("no agent wallet");
        services.setServiceWallet(svcId, makeAddr("serviceWallet"));
    }

    function test_setServiceWallet_nonAuthReverts() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");
        vm.prank(otherUser);
        vm.expectRevert("not owner or operator");
        services.setServiceWallet(svcId, otherUser);
    }

    function test_resolveSettlementRestoresExactStateBoundOverride() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");
        address serviceWallet = makeAddr("serviceWallet");
        vm.prank(provider);
        services.setServiceWallet(svcId, serviceWallet);

        address interimOwner = makeAddr("interimOwner");
        vm.prank(provider);
        identity.transferFrom(provider, interimOwner, providerAgentId);
        vm.prank(interimOwner);
        identity.transferFrom(interimOwner, provider, providerAgentId);
        identity.forceSetAgentWallet(providerAgentId, provider);

        (uint256 resolvedProvider, bool active, address owner, address wallet, address payee) =
            services.resolveSettlement(svcId);
        assertEq(resolvedProvider, providerAgentId);
        assertTrue(active);
        assertEq(owner, provider);
        assertEq(wallet, provider);
        assertEq(payee, serviceWallet);
    }

    function test_updateServiceURI() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");

        vm.expectEmit(true, false, false, true, address(services));
        emit IServiceRegistry.ServiceURIUpdated(svcId, "ipfs://new");
        vm.prank(provider);
        services.updateServiceURI(svcId, "ipfs://new");
        assertEq(services.getService(svcId).serviceURI, "ipfs://new");
    }

    function test_setActive() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");
        assertTrue(services.isActive(svcId));

        vm.prank(provider);
        services.setActive(svcId, false);
        assertFalse(services.isActive(svcId));

        vm.prank(provider);
        services.setActive(svcId, true);
        assertTrue(services.isActive(svcId));
    }

    function test_setActive_nonAuthReverts() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");
        vm.prank(otherUser);
        vm.expectRevert("not owner or operator");
        services.setActive(svcId, false);
    }

    function test_serviceNotFoundReverts() public {
        bytes32 ghost = bytes32(uint256(0xDEAD));
        vm.expectRevert("service not found");
        services.getService(ghost);
        vm.prank(provider);
        vm.expectRevert("service not found");
        services.setActive(ghost, false);
        vm.prank(provider);
        vm.expectRevert("service not found");
        services.setServiceWallet(ghost, provider);
        vm.prank(provider);
        vm.expectRevert("service not found");
        services.updateServiceURI(ghost, "u");
    }

    // ── NFT transfer flips authority ────────────────────────────────

    function test_nftTransfer_newOwnerCanRegister_oldOwnerCannot() public {
        address newOwner = makeAddr("newOwner");

        // Provider transfers the NFT.
        vm.prank(provider);
        identity.transferFrom(provider, newOwner, providerAgentId);
        assertEq(identity.ownerOf(providerAgentId), newOwner);

        // Old owner can no longer register services.
        vm.prank(provider);
        vm.expectRevert("not owner or operator");
        services.registerService(providerAgentId, "x", "1", "u", address(0));

        // New owner can — provided the underlying provider is still active
        // (which it is — setActive was not flipped). NFT transfer doesn't
        // touch the Daski provider row.
        vm.prank(newOwner);
        bytes32 svcId = services.registerService(providerAgentId, "x", "1", "u", address(0));
        assertEq(services.getService(svcId).providerAgentId, providerAgentId);
    }

    // ── Enumeration ─────────────────────────────────────────────────

    function test_enumeration() public {
        bytes32 a = _registerSimple(provider, "a", "1");
        bytes32 b = _registerSimple(provider, "b", "1");
        bytes32 c = _registerSimple(provider, "c", "1");

        assertEq(services.getServiceCountByProvider(providerAgentId), 3);
        bytes32[] memory all = services.getServicesByProviderPaginated(providerAgentId, 0, 3);
        assertEq(all.length, 3);
        assertEq(all[0], a);
        assertEq(all[1], b);
        assertEq(all[2], c);

        bytes32[] memory page = services.getServicesByProviderPaginated(providerAgentId, 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], b);

        bytes32[] memory tail = services.getServicesByProviderPaginated(providerAgentId, 2, 100);
        assertEq(tail.length, 1);
        assertEq(tail[0], c);

        bytes32[] memory past = services.getServicesByProviderPaginated(providerAgentId, 3, 1);
        assertEq(past.length, 0);
    }

    function test_deactivate_keepsRow() public {
        bytes32 svcId = _registerSimple(provider, "skill", "1");
        vm.prank(provider);
        services.setActive(svcId, false);

        // exists() and getService() still resolve so historical payment
        // records and reputation queries can read service metadata after
        // deactivation.
        assertTrue(services.exists(svcId));
        assertFalse(services.isActive(svcId));
        IServiceRegistry.Service memory svc = services.getService(svcId);
        assertEq(svc.providerAgentId, providerAgentId);
    }

    // ── Admin ───────────────────────────────────────────────────────

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        services.transferAdmin(newAdmin);
        assertEq(services.pendingAdmin(), newAdmin);
        assertEq(services.admin(), admin);

        vm.prank(makeAddr("rand"));
        vm.expectRevert("not pending admin");
        services.acceptAdmin();

        vm.prank(newAdmin);
        services.acceptAdmin();
        assertEq(services.admin(), newAdmin);
    }
}
