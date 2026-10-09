// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {IEAS, RevocationRequest, RevocationRequestData} from "../src/interfaces/IEAS.sol";
import {NativeEASReputationTestBase} from "./helpers/NativeEASReputationTestBase.sol";
import {ReputationStateSnapshot} from "./helpers/ReputationStateSnapshot.sol";

/// In-place upgrade of a populated 2.1.0 resolver to the current implementation.
///
/// The 2.1.0 implementation is test/vectors/reputation-storage-2.1.0.json: the
/// creation bytecode of src/ReputationStorage.sol (version "2.1.0") built from
/// commit b0262359c8b06ca102e143578ecd72b2de5a4a54 with this repository's
/// foundry.toml (solc 0.8.24, via-IR, 200 optimizer runs, cancun). Its hash is
/// checked before deployment.
abstract contract ReputationUpgradePreservationTest is NativeEASReputationTestBase, ReputationStateSnapshot {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant RECOVERY_SCHEMA_SLOT = 140;
    uint256 private constant RECOVERY_ENABLED_SLOT = 141;

    address private guardian = makeAddr("pause-guardian");

    bytes32[] private _orderKeys;
    bytes32[] private _authorizationKeys;
    bytes32[] private _confirmationUids;
    bytes32 private _recoverable;

    function setUp() public override {
        super.setUp();
        reputation = _deployProxy(_deployLegacyImplementation());
        _finalize(reputation);
        vm.prank(admin);
        reputation.setPauseGuardian(guardian);
        _populate();
    }

    function test_upgradeOfPopulatedResolverKeepsEveryRecordAndCounter() public {
        SnapshotKeys memory keys = _snapshotKeys();
        bytes[] memory getters = _getterResults(address(reputation), keys);
        bytes32[] memory words = _rawWords(address(reputation), keys);
        _assertLayoutReadsTheGetters();
        // The appended state comes from gap words the 2.1.0 resolver never wrote.
        for (uint256 slot = RECOVERY_SCHEMA_SLOT; slot < LAYOUT_SLOTS; ++slot) {
            assertEq(words[slot], bytes32(0));
        }

        // The 2.1.0 resolver refuses recovery attestations: it knows no recovery schema.
        recoverySchema = _registerRecoverySchema(address(reputation));
        vm.expectRevert(ReputationStorageBase.UnknownSchema.selector);
        _attestRecovery(providerWallet, providerWallet, _recoverable, keccak256("early"));

        ReputationStorage next = new ReputationStorage();
        vm.expectEmit(true, false, false, true, address(reputation));
        emit IERC1967.Upgraded(address(next));
        vm.expectEmit(true, false, false, true, address(reputation));
        emit ReputationStorageBase.RecoverySchemaConfigured(recoverySchema);
        vm.prank(admin);
        reputation.upgradeToAndCall(address(next), abi.encodeCall(reputation.configureRecoverySchema, (recoverySchema)));

        assertEq(address(uint160(uint256(vm.load(address(reputation), ERC1967_IMPLEMENTATION_SLOT)))), address(next));
        assertEq(reputation.version(), "2.2.0");
        _assertSameResults(getters, _getterResults(address(reputation), keys));
        bytes32[] memory upgraded = _rawWords(address(reputation), keys);
        _assertSameWordsExceptRecoveryConfiguration(words, upgraded);
        assertEq(upgraded[RECOVERY_SCHEMA_SLOT], recoverySchema);
        assertEq(upgraded[RECOVERY_ENABLED_SLOT], bytes32(0));

        // The recovery state starts empty.
        assertEq(reputation.recoverySchema(), recoverySchema);
        assertFalse(reputation.recoverySubmissionsEnabled());
        for (uint256 i; i < keys.orders.length; ++i) {
            assertEq(_recovery(keys.orders[i]), abi.encode(uint64(0), bytes32(0), bytes32(0)));
        }
        for (uint256 i; i < keys.providers.length; ++i) {
            assertEq(reputation.recoveredCount(keys.providers[i]), 0);
        }
        for (uint256 i; i < keys.services.length; ++i) {
            assertEq(reputation.recoveredByService(keys.services[i]), 0);
        }

        // Enabling and recording one recovery on a Failed order changes only recovery state.
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(true);
        vm.warp(block.timestamp + 2 days);
        bytes32 evidence = keccak256("recovery-after-upgrade");
        bytes32 uid = _attestRecovery(providerWallet, providerWallet, _recoverable, evidence);

        assertEq(_recovery(_recoverable), abi.encode(uint64(block.timestamp), evidence, uid));
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 1);
        assertEq(reputation.recoveredCount(SECOND_AGENT_ID), 0);
        assertEq(reputation.recoveredByService(serviceId), 0);
        assertEq(reputation.recoveredByService(secondServiceId), 1);
        assertEq(reputation.recoveredByService(thirdServiceId), 0);
        for (uint256 i; i < keys.orders.length; ++i) {
            if (keys.orders[i] == _recoverable) continue;
            assertEq(_recovery(keys.orders[i]), abi.encode(uint64(0), bytes32(0), bytes32(0)));
        }
        _assertSameResults(getters, _getterResults(address(reputation), keys));
        bytes32[] memory recovered = _rawWords(address(reputation), keys);
        _assertSameWordsExceptRecoveryConfiguration(words, recovered);
        assertEq(recovered[RECOVERY_SCHEMA_SLOT], recoverySchema);
        assertEq(recovered[RECOVERY_ENABLED_SLOT], bytes32(uint256(1)));
    }

    function _deployLegacyImplementation() private returns (address implementation) {
        string memory fixture = vm.readFile("test/vectors/reputation-storage-2.1.0.json");
        bytes memory code = vm.parseJsonBytes(fixture, ".creationCode");
        assertEq(keccak256(code), vm.parseJsonBytes32(fixture, ".creationCodeHash"));
        assembly ("memory-safe") {
            implementation := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(implementation != address(0), "2.1.0 implementation not deployed");
        assertEq(ReputationStorage(implementation).version(), "2.1.0");
    }

    /// Two providers, three services and two payers: Completed, Failed and Canceled
    /// outcomes from the agent wallet and the owner, partial and full refunds,
    /// confirmation revisions and a revocation, pending and ineligible orders.
    function _populate() private {
        bytes32 order = _record("completed-revised", PROVIDER_AGENT_ID, serviceId, payer, 100e6, true);
        vm.warp(block.timestamp + 1 hours);
        _attestOutcome(order, ReputationStorageBase.TransactionOutcome.Completed);
        bytes32 uid = _confirm(payer, order, 1, bytes32(0));
        uid = _confirm(payer, order, 2, uid);
        _confirm(payer, order, 1, uid);

        order = _record("failed-partially-refunded", PROVIDER_AGENT_ID, serviceId, secondPayer, 100e6, true);
        vm.warp(block.timestamp + 2 hours);
        _attestOutcome(order, ReputationStorageBase.TransactionOutcome.Failed);
        _refund(_refundPermit(order, 30e6));

        _recoverable = _record("failed-recoverable", PROVIDER_AGENT_ID, secondServiceId, payer, 2_000_000, true);
        vm.warp(block.timestamp + 3 hours);
        _attestOutcome(_recoverable, ReputationStorageBase.TransactionOutcome.Failed);
        _confirm(payer, _recoverable, 2, bytes32(0));

        order = _record("canceled-revoked", PROVIDER_AGENT_ID, secondServiceId, secondPayer, 50e6, true);
        _attestOutcome(order, ReputationStorageBase.TransactionOutcome.Canceled);
        uid = _confirm(secondPayer, order, 1, bytes32(0));
        vm.warp(block.timestamp + 1);
        _revoke(secondPayer, uid);

        order = _record("failed-owner-attested", SECOND_AGENT_ID, thirdServiceId, payer, 75e6, true);
        vm.warp(block.timestamp + 5 hours);
        _attestAs(secondOwner, outcomeSchema, secondWallet, false, bytes32(0), abi.encode(order, uint8(1)));
        _confirm(payer, order, 2, bytes32(0));

        order = _record("pending-confirmed", SECOND_AGENT_ID, thirdServiceId, secondPayer, 10e6, true);
        _confirm(secondPayer, order, 1, bytes32(0));

        order = _record("ineligible-refunded", SECOND_AGENT_ID, thirdServiceId, payer, 20e6, false);
        _refund(_refundPermit(order, 20e6));

        order = _record("completed-fully-refunded", PROVIDER_AGENT_ID, serviceId, payer, 100e6, true);
        _attestOutcome(order, ReputationStorageBase.TransactionOutcome.Completed);
        _refund(_refundPermit(order, 100e6));

        _record("pending", PROVIDER_AGENT_ID, serviceId, secondPayer, 3_000_000, true);
    }

    /// Registers an order and keeps its keys for the snapshots.
    function _record(
        string memory label,
        uint256 agentId,
        bytes32 service,
        address buyer,
        uint256 grossAmount,
        bool eligible
    ) private returns (bytes32 orderKey) {
        orderKey = _order(label, agentId, service, buyer, grossAmount, eligible);
        _orderKeys.push(orderKey);
        _authorizationKeys.push(reputation.getRecord(orderKey).authorizationKey);
    }

    function _confirm(address buyer, bytes32 orderKey, uint8 choice, bytes32 refUID) private returns (bytes32 uid) {
        address recipient = reputation.getRecord(orderKey).providerAgentWallet;
        uid = _attestAs(buyer, confirmationSchema, recipient, true, refUID, abi.encode(orderKey, choice));
        _confirmationUids.push(uid);
    }

    function _revoke(address buyer, bytes32 uid) private {
        vm.prank(buyer);
        IEAS(NATIVE_EAS)
            .revoke(RevocationRequest({schema: confirmationSchema, data: RevocationRequestData({uid: uid, value: 0})}));
    }

    function _snapshotKeys() private view returns (SnapshotKeys memory keys) {
        keys.orders = _orderKeys;
        keys.authorizations = _authorizationKeys;
        keys.confirmationUids = _confirmationUids;
        keys.providers = new uint256[](2);
        keys.providers[0] = PROVIDER_AGENT_ID;
        keys.providers[1] = SECOND_AGENT_ID;
        keys.services = new bytes32[](3);
        keys.services[0] = serviceId;
        keys.services[1] = secondServiceId;
        keys.services[2] = thirdServiceId;
        keys.payers = new address[](2);
        keys.payers[0] = payer;
        keys.payers[1] = secondPayer;
    }

    function _assertSameWordsExceptRecoveryConfiguration(bytes32[] memory before, bytes32[] memory afterwards)
        private
        pure
    {
        assertEq(before.length, afterwards.length, "word count");
        for (uint256 i; i < before.length; ++i) {
            if (i == RECOVERY_SCHEMA_SLOT || i == RECOVERY_ENABLED_SLOT) continue;
            assertEq(before[i], afterwards[i], string.concat("storage word ", vm.toString(i)));
        }
    }

    /// The raw words compared above are the ones the getters read, so the comparison is not vacuous.
    function _assertLayoutReadsTheGetters() private view {
        address target = address(reputation);
        assertEq(address(uint160(uint256(vm.load(target, bytes32(uint256(50)))))), admin);
        assertEq(vm.load(target, bytes32(uint256(137))), outcomeSchema);
        assertEq(vm.load(target, bytes32(uint256(138))), confirmationSchema);
        assertEq(uint256(vm.load(target, bytes32(RECORDS_SLOT + 1))), _orderKeys.length);
        assertEq(vm.load(target, bytes32(_mappingSlot(_recoverable, RECORDS_SLOT))), _recoverable);
        uint256 failed = reputation.failedCount(PROVIDER_AGENT_ID);
        assertEq(failed, 2);
        assertEq(uint256(vm.load(target, bytes32(_mappingSlot(bytes32(PROVIDER_AGENT_ID), 107)))), failed);
        assertEq(uint256(vm.load(target, bytes32(_mappingSlot(thirdServiceId, 116)))), 1);
        assertEq(
            uint256(vm.load(target, bytes32(_mappingSlot(bytes32(uint256(uint160(payer))), 127)))),
            reputation.refundedAmountByPayer(payer)
        );
        assertGt(reputation.refundedAmountByPayer(payer), 0);
    }
}

contract EASLegacy101UpgradePreservationTest is ReputationUpgradePreservationTest {
    function _legacy() internal pure override returns (bool) {
        return true;
    }
}

contract EASDeadline120UpgradePreservationTest is ReputationUpgradePreservationTest {
    function _legacy() internal pure override returns (bool) {
        return false;
    }
}
