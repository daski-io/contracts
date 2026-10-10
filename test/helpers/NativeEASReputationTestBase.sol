// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../../src/reputation/ReputationStorageBase.sol";
import {AttestationRequest, AttestationRequestData, IEAS, ISchemaRegistry} from "../../src/interfaces/IEAS.sol";
import {MockEAS} from "./MockEAS.sol";
import {MockSanctionsList} from "../mocks/MockSanctionsList.sol";
import {
    ProviderRegistryStub,
    RegistryCodeStub,
    ReputationTestBase,
    ServiceRegistryStub
} from "./ReputationTestBase.sol";

/// The actual pinned EAS and SchemaRegistry runtimes, installed offline at their
/// canonical predeploy addresses after their code hashes are checked (see
/// docs/eas-native-profiles.md). EAS itself assigns every attestation uid and
/// time, refuses revocable attestations under irrevocable schemas and unknown
/// references, and calls the resolver exactly as on chain.
abstract contract NativeEASFixture is Test {
    address internal constant NATIVE_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant NATIVE_REGISTRY = 0x4200000000000000000000000000000000000020;
    string internal constant RECOVERY_SCHEMA = "bytes32 orderKey,bytes32 recoveryEvidenceHash";

    /// True installs the Base runtime (EAS 1.0.1), false the Base Sepolia runtime (EAS 1.2.0),
    /// and selects the matching chain id.
    function _installNativeEAS(bool legacy) internal {
        string memory fixture =
            vm.readFile(legacy ? "test/vectors/eas/base-8453.json" : "test/vectors/eas/base-84532.json");
        vm.chainId(legacy ? 8453 : 84532);
        vm.warp(1_790_000_000);
        bytes memory code = vm.parseJsonBytes(fixture, ".eas.runtimeCode");
        assertEq(keccak256(code), vm.parseJsonBytes32(fixture, ".eas.runtimeCodeHash"));
        vm.etch(NATIVE_EAS, code);
        code = vm.parseJsonBytes(fixture, ".schemaRegistry.runtimeCode");
        assertEq(keccak256(code), vm.parseJsonBytes32(fixture, ".schemaRegistry.runtimeCodeHash"));
        vm.etch(NATIVE_REGISTRY, code);
    }
}

/// Reputation fixtures on the native EAS runtimes, with a second provider, its
/// participants, a second payer and three services.
abstract contract NativeEASReputationTestBase is ReputationTestBase, NativeEASFixture {
    uint256 internal constant SECOND_AGENT_ID = 8061;

    bytes32 internal secondServiceId = keccak256("mailboxes-v1");
    bytes32 internal thirdServiceId = keccak256("entity-formation-v1");
    address internal secondPayer = makeAddr("second-payer");
    address internal secondOwner = makeAddr("second-provider-owner");
    address internal secondWallet = makeAddr("second-provider-wallet");
    address internal secondPayee = makeAddr("second-provider-payee");
    bytes32 internal recoverySchema;

    /// True runs on the Base runtime (EAS 1.0.1), false on Base Sepolia (EAS 1.2.0).
    function _legacy() internal pure virtual returns (bool);

    /// Installs EAS and the order dependencies; each suite deploys and configures its resolver.
    function setUp() public virtual override {
        _installNativeEAS(_legacy());
        // The base helpers call attest/revoke through this type; the selectors are the EAS ones.
        eas = MockEAS(NATIVE_EAS);
        identity = new RegistryCodeStub();
        providers = new ProviderRegistryStub();
        services = new ServiceRegistryStub();
        sanctions = new MockSanctionsList();
        token = address(new RegistryCodeStub());
        providers.setRegistered(PROVIDER_AGENT_ID, true);
        providers.setRegistered(SECOND_AGENT_ID, true);
        services.setService(serviceId, PROVIDER_AGENT_ID);
        services.setService(secondServiceId, PROVIDER_AGENT_ID);
        services.setService(thirdServiceId, SECOND_AGENT_ID);
    }

    /// Registers a signed order of either provider for `buyer`.
    function _order(
        string memory label,
        uint256 agentId,
        bytes32 service,
        address buyer,
        uint256 grossAmount,
        bool eligible
    ) internal returns (bytes32 orderKey) {
        orderKey = keccak256(bytes(label));
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(orderKey);
        permit.providerAgentId = agentId;
        permit.serviceId = service;
        permit.payer = buyer;
        if (agentId == SECOND_AGENT_ID) {
            permit.providerOwner = secondOwner;
            permit.providerAgentWallet = secondWallet;
            permit.providerPayee = secondPayee;
        }
        permit.grossAmount = grossAmount;
        permit.reputationEligible = eligible;
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
        _register(permit);
    }

    function _deployProxy(address implementation) internal returns (ReputationStorage) {
        return ReputationStorage(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            vm.addr(ORDER_SIGNER_KEY),
                            address(identity),
                            address(providers),
                            address(services),
                            address(sanctions),
                            token,
                            admin
                        )
                    )
                )
            )
        );
    }

    /// Registers the outcome and confirmation schemas to `target` and finalizes it.
    function _finalize(ReputationStorage target) internal {
        outcomeSchema =
            ISchemaRegistry(NATIVE_REGISTRY).register("bytes32 orderKey,uint8 outcome", address(target), false);
        confirmationSchema =
            ISchemaRegistry(NATIVE_REGISTRY).register("bytes32 orderKey,uint8 confirmation", address(target), true);
        vm.startPrank(admin);
        target.setEAS(NATIVE_EAS);
        target.setOutcomeSchema(outcomeSchema);
        target.setConfirmationSchema(confirmationSchema);
        target.finalizeConfiguration();
        vm.stopPrank();
    }

    function _registerRecoverySchema(address resolver) internal returns (bytes32) {
        return ISchemaRegistry(NATIVE_REGISTRY).register(RECOVERY_SCHEMA, resolver, false);
    }

    /// Deploys, finalizes, configures and enables a current resolver as `reputation`.
    function _deployRecoveryReady() internal {
        reputation = _deployProxy(address(new ReputationStorage()));
        _finalize(reputation);
        recoverySchema = _registerRecoverySchema(address(reputation));
        vm.startPrank(admin);
        reputation.configureRecoverySchema(recoverySchema);
        reputation.setRecoverySubmissionsEnabled(true);
        vm.stopPrank();
    }

    /// A direct EAS attestation sent by `attester` itself.
    function _attestAs(
        address attester,
        bytes32 schema,
        address recipient,
        bool revocable,
        bytes32 refUID,
        bytes memory data
    ) internal returns (bytes32) {
        AttestationRequest memory request = AttestationRequest({
            schema: schema,
            data: AttestationRequestData({
                recipient: recipient, expirationTime: 0, revocable: revocable, refUID: refUID, data: data, value: 0
            })
        });
        vm.prank(attester);
        return IEAS(NATIVE_EAS).attest(request);
    }

    function _attestOutcome(bytes32 orderKey, ReputationStorageBase.TransactionOutcome outcome)
        internal
        returns (bytes32)
    {
        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        return _attestAs(
            record.providerAgentWallet,
            outcomeSchema,
            record.providerAgentWallet,
            false,
            bytes32(0),
            abi.encode(orderKey, uint8(outcome))
        );
    }

    function _attestRecovery(address attester, address recipient, bytes32 orderKey, bytes32 evidenceHash)
        internal
        returns (bytes32)
    {
        return _attestAs(attester, recoverySchema, recipient, false, bytes32(0), abi.encode(orderKey, evidenceHash));
    }

    /// The uid EAS assigns to a first (unbumped) attestation made at the current time.
    function _expectedUid(
        bytes32 schema,
        address recipient,
        address attester,
        bool revocable,
        bytes32 refUID,
        bytes memory data
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                schema, recipient, attester, uint64(block.timestamp), uint64(0), revocable, refUID, data, uint32(0)
            )
        );
    }

    function _recovery(bytes32 orderKey) internal view returns (bytes memory) {
        (uint64 recoveredAt, bytes32 evidenceHash, bytes32 attestationUid) = reputation.getRecovery(orderKey);
        return abi.encode(recoveredAt, evidenceHash, attestationUid);
    }

    function _refundPermit(bytes32 orderKey, uint256 cumulative)
        internal
        view
        returns (ReputationStorageBase.StandardReputationRefundV1 memory)
    {
        return ReputationStorageBase.StandardReputationRefundV1({
            orderKey: orderKey,
            authorizationKey: reputation.getRecord(orderKey).authorizationKey,
            cumulativeRefundedAmount: cumulative,
            refundEvidenceHash: keccak256(abi.encode("refund", orderKey, cumulative)),
            validBefore: uint64(block.timestamp + 5 minutes)
        });
    }
}
