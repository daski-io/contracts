// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract ReputationAgentZeroIntegrationTest is Test {
    uint256 private constant ORDER_SIGNER_KEY = 0xA11CE;

    address private admin = makeAddr("admin");
    address private payer = makeAddr("payer");
    address private providerOwner = makeAddr("provider-owner");
    address private treasury = makeAddr("treasury");

    MockCanonicalIdentityRegistry private identity;
    ProviderRegistry private providers;
    ServiceRegistry private services;
    ReputationStorage private reputation;
    MockEAS private eas;
    MockSanctionsList private sanctions;
    MockUSDC private token;
    bytes32 private serviceId;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();
        token = new MockUSDC();

        ProviderRegistry providerImplementation = new ProviderRegistry();
        providers = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(providerImplementation),
                    abi.encodeCall(
                        ProviderRegistry.initialize,
                        (address(identity), address(token), treasury, 0, address(sanctions), admin)
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

        vm.prank(providerOwner);
        uint256 providerAgentId = identity.register("https://provider.example/agent.json");
        assertEq(providerAgentId, 0);
        vm.prank(providerOwner);
        providers.register(providerAgentId);
        vm.prank(providerOwner);
        serviceId = services.registerService(
            providerAgentId, "domain-management", "1", "https://provider.example/service.json", address(0)
        );

        ReputationStorage reputationImplementation = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(reputationImplementation),
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            vm.addr(ORDER_SIGNER_KEY),
                            address(identity),
                            address(providers),
                            address(services),
                            address(sanctions),
                            address(token),
                            admin
                        )
                    )
                )
            )
        );
        eas = new MockEAS();
        bytes32 outcomeSchema = eas.register("bytes32 orderKey,uint8 outcome", address(reputation), false);
        bytes32 confirmationSchema = eas.register("bytes32 orderKey,uint8 confirmation", address(reputation), true);
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        vm.stopPrank();
    }

    function test_firstCanonicalAgentCanAccrueStandardOrderReputation() public {
        bytes32 orderKey = keccak256("agent-zero-order");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = ReputationStorageBase.StandardReputationOrderV1({
            orderKey: orderKey,
            authorizationKey: keccak256("agent-zero-authorization"),
            providerAgentId: 0,
            serviceId: serviceId,
            payer: payer,
            providerOwner: providerOwner,
            providerAgentWallet: providerOwner,
            providerPayee: providerOwner,
            identityRegistry: address(identity),
            providerRegistry: address(providers),
            serviceRegistry: address(services),
            blockNumber: block.number,
            blockHash: keccak256("snapshot-block"),
            canonicalToken: address(token),
            grossAmount: 100e6,
            paidAt: uint64(block.timestamp),
            providerIdentitySnapshotHash: bytes32(0),
            listingManifestHash: keccak256("listing"),
            releaseEvidenceHash: keccak256("release"),
            reputationEligible: true,
            validBefore: uint64(block.timestamp + 5 minutes)
        });
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
        bytes32 digest = reputation.orderDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);

        reputation.registerOrder(permit, abi.encodePacked(r, s, v));

        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(record.providerAgentId, 0);
        assertEq(record.serviceId, serviceId);
        (,,,,, uint256 providerTransactions) = reputation.getProviderStats(0);
        assertEq(providerTransactions, 1);
        (,,,,,, uint256 serviceTransactions) = reputation.getServiceStats(serviceId);
        assertEq(serviceTransactions, 1);
    }
}
