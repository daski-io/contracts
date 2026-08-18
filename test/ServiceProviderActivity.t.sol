// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {IServiceRegistry} from "../src/interfaces/IServiceRegistry.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract ServiceProviderActivityTest is Test {
    MockCanonicalIdentityRegistry private identity;
    ProviderRegistry private providers;
    ServiceRegistry private services;

    address private admin = makeAddr("admin");
    address private treasury = makeAddr("treasury");
    address private provider = makeAddr("provider");
    uint256 private providerAgentId;
    bytes32 private serviceId;

    function setUp() public {
        identity = new MockCanonicalIdentityRegistry();
        MockSanctionsList sanctions = new MockSanctionsList();
        MockUSDC usdc = new MockUSDC();

        ProviderRegistry providerImplementation = new ProviderRegistry();
        providers = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(providerImplementation),
                    abi.encodeCall(
                        ProviderRegistry.initialize,
                        (address(identity), address(usdc), treasury, 1_000_000, address(sanctions), admin)
                    )
                )
            )
        );

        ServiceRegistry serviceImplementation = new ServiceRegistry();
        services = ServiceRegistry(
            address(
                new ERC1967Proxy(
                    address(serviceImplementation),
                    abi.encodeCall(
                        ServiceRegistry.initialize, (address(identity), address(providers), address(sanctions), admin)
                    )
                )
            )
        );

        vm.prank(provider);
        providerAgentId = identity.register("ipfs://provider");
        usdc.mint(provider, 1_000_000);
        vm.startPrank(provider);
        usdc.approve(address(providers), 1_000_000);
        providers.register(providerAgentId);
        serviceId = services.registerService(providerAgentId, "service", "1", "ipfs://service", address(0));
        vm.stopPrank();
    }

    function test_providerDeactivationDisablesSettlementButPreservesMaintenance() public {
        assertTrue(services.isActive(serviceId));

        vm.prank(provider);
        providers.setActive(providerAgentId, false);

        assertFalse(services.isActive(serviceId));
        (uint256 resolvedProvider, bool active, address owner, address wallet, address payee) =
            services.resolveSettlement(serviceId);
        assertEq(resolvedProvider, providerAgentId);
        assertFalse(active);
        assertEq(owner, provider);
        assertEq(wallet, provider);
        assertEq(payee, provider);

        vm.prank(provider);
        services.updateServiceURI(serviceId, "ipfs://updated");
        IServiceRegistry.Service memory service = services.getService(serviceId);
        assertTrue(service.active, "local activity is preserved");
        assertEq(service.serviceURI, "ipfs://updated");

        vm.prank(provider);
        providers.setActive(providerAgentId, true);
        assertTrue(services.isActive(serviceId));
    }
}
