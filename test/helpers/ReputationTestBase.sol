// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../../src/reputation/ReputationStorageBase.sol";
import {IServiceRegistry} from "../../src/interfaces/IServiceRegistry.sol";
import {Attestation} from "../../src/interfaces/IEAS.sol";
import {MockEAS} from "./MockEAS.sol";
import {MockSanctionsList} from "../mocks/MockSanctionsList.sol";

contract RegistryCodeStub {}

contract ProviderRegistryStub {
    mapping(uint256 => bool) public isRegistered;

    function setRegistered(uint256 agentId, bool registered) external {
        isRegistered[agentId] = registered;
    }
}

contract ServiceRegistryStub {
    mapping(bytes32 => IServiceRegistry.Service) private _services;

    function setService(bytes32 serviceId, uint256 providerAgentId) external {
        _services[serviceId] = IServiceRegistry.Service({
            providerAgentId: providerAgentId,
            serviceId: serviceId,
            serviceSlug: "domain-management",
            version: "1",
            serviceURI: "https://provider.example/service.json",
            serviceWallet: address(0),
            serviceWalletOwner: address(0),
            serviceWalletAgentWallet: address(0),
            createdAt: uint64(block.timestamp),
            active: true
        });
    }

    function getService(bytes32 serviceId) external view returns (IServiceRegistry.Service memory) {
        require(_services[serviceId].serviceId != bytes32(0), "service not found");
        return _services[serviceId];
    }
}

abstract contract ReputationTestBase is Test {
    uint256 internal constant ORDER_SIGNER_KEY = 0xA11CE;
    uint256 internal constant PROVIDER_AGENT_ID = 8060;

    address internal admin = makeAddr("admin");
    address internal payer = makeAddr("payer");
    address internal providerOwner = makeAddr("provider-owner");
    address internal providerWallet = makeAddr("provider-wallet");
    address internal providerPayee = makeAddr("provider-payee");
    address internal token = makeAddr("usdc");
    bytes32 internal serviceId = keccak256("domain-management-v1");

    RegistryCodeStub internal identity;
    ProviderRegistryStub internal providers;
    ServiceRegistryStub internal services;
    MockSanctionsList internal sanctions;
    MockEAS internal eas;
    ReputationStorage internal reputation;
    bytes32 internal outcomeSchema;
    bytes32 internal confirmationSchema;

    function setUp() public virtual {
        identity = new RegistryCodeStub();
        providers = new ProviderRegistryStub();
        services = new ServiceRegistryStub();
        sanctions = new MockSanctionsList();
        providers.setRegistered(PROVIDER_AGENT_ID, true);
        services.setService(serviceId, PROVIDER_AGENT_ID);

        ReputationStorage implementation = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            vm.addr(ORDER_SIGNER_KEY),
                            address(identity),
                            address(providers),
                            address(services),
                            address(sanctions),
                            admin
                        )
                    )
                )
            )
        );
        eas = new MockEAS();
        outcomeSchema = eas.register("bytes32 orderKey,uint8 outcome", address(reputation), false);
        confirmationSchema = eas.register("bytes32 orderKey,uint8 confirmation", address(reputation), true);
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        vm.stopPrank();
    }

    function _permit(bytes32 orderKey)
        internal
        view
        returns (ReputationStorageBase.StandardReputationOrderV1 memory permit)
    {
        permit = ReputationStorageBase.StandardReputationOrderV1({
            orderKey: orderKey,
            authorizationKey: keccak256(abi.encode("authorization", orderKey)),
            providerAgentId: PROVIDER_AGENT_ID,
            serviceId: serviceId,
            payer: payer,
            providerOwner: providerOwner,
            providerAgentWallet: providerWallet,
            providerPayee: providerPayee,
            identityRegistry: address(identity),
            providerRegistry: address(providers),
            serviceRegistry: address(services),
            blockNumber: block.number,
            blockHash: keccak256(abi.encode("block", block.number)),
            canonicalToken: token,
            grossAmount: 100e6,
            paidAt: uint64(block.timestamp),
            providerIdentitySnapshotHash: bytes32(0),
            listingManifestHash: keccak256("listing"),
            releaseEvidenceHash: keccak256("release"),
            reputationEligible: true,
            validBefore: uint64(block.timestamp + 5 minutes)
        });
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
    }

    function _register(ReputationStorageBase.StandardReputationOrderV1 memory permit) internal {
        bytes32 digest = reputation.orderDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));
    }

    function _refund(ReputationStorageBase.StandardReputationRefundV1 memory permit) internal {
        reputation.recordRefund(permit, _refundSignature(permit));
    }

    function _refundSignature(ReputationStorageBase.StandardReputationRefundV1 memory permit)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = reputation.refundDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attestation(
        bytes32 uid,
        bytes32 schema,
        address attester,
        bytes32 orderKey,
        uint8 value,
        bool revocable,
        bytes32 refUid
    ) internal view returns (Attestation memory) {
        return Attestation({
            uid: uid,
            schema: schema,
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: 0,
            refUID: refUid,
            recipient: providerWallet,
            attester: attester,
            revocable: revocable,
            data: abi.encode(orderKey, value)
        });
    }
}
