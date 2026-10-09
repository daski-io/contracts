// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {
    Attestation,
    AttestationRequestData,
    IEAS,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";
import {NativeEASReputationTestBase} from "./helpers/NativeEASReputationTestBase.sol";
import {ReputationStateSnapshot} from "./helpers/ReputationStateSnapshot.sol";

struct MultiAttestationRequest {
    bytes32 schema;
    AttestationRequestData[] data;
}

interface INativeMultiAttest {
    function multiAttest(MultiAttestationRequest[] calldata multiRequests) external payable returns (bytes32[] memory);
}

/// Provider recovery attestations sent through the actual EAS runtimes. A refused
/// recovery leaves the recovery record and both recovery counters untouched; an
/// accepted one changes nothing else.
abstract contract ReputationRecoveryTest is NativeEASReputationTestBase, ReputationStateSnapshot {
    bytes32 internal constant FAILED = keccak256("recovery-failed-order");
    bytes32 internal constant EVIDENCE = keccak256("recovery-evidence");
    bytes4 internal constant EAS_IRREVOCABLE = bytes4(keccak256("Irrevocable()"));

    bytes32 internal failedOutcomeUid;

    function setUp() public override {
        super.setUp();
        _deployRecoveryReady();
        _register(_permit(FAILED));
        vm.warp(block.timestamp + 1 hours);
        failedOutcomeUid = _attestOutcome(FAILED, ReputationStorageBase.TransactionOutcome.Failed);
        vm.warp(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------
    // Accepted recoveries
    // ------------------------------------------------------------------

    function test_agentWalletRecordsRecoveryBesideTheFailedOutcome() public {
        _assertRecovered(providerWallet);
    }

    function test_providerOwnerRecordsRecoveryBesideTheFailedOutcome() public {
        _assertRecovered(providerOwner);
    }

    function test_batchRecordsEveryRecoveryOrNone() public {
        bytes32 second = _failedOrder("batch-second");
        AttestationRequestData[] memory data = new AttestationRequestData[](2);
        data[0] = _recoveryRequest(FAILED, EVIDENCE);
        data[1] = _recoveryRequest(second, bytes32(0));
        MultiAttestationRequest[] memory requests = new MultiAttestationRequest[](1);
        requests[0] = MultiAttestationRequest({schema: recoverySchema, data: data});

        vm.prank(providerWallet);
        vm.expectRevert(ReputationStorageBase.InvalidRecoveryEncoding.selector);
        INativeMultiAttest(NATIVE_EAS).multiAttest(requests);
        assertEq(_recovery(FAILED), _notRecovered());
        assertEq(_recovery(second), _notRecovered());
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 0);

        data[1] = _recoveryRequest(second, keccak256("second-evidence"));
        vm.prank(providerWallet);
        bytes32[] memory uids = INativeMultiAttest(NATIVE_EAS).multiAttest(requests);
        assertEq(_recovery(FAILED), abi.encode(uint64(block.timestamp), EVIDENCE, uids[0]));
        assertEq(_recovery(second), abi.encode(uint64(block.timestamp), keccak256("second-evidence"), uids[1]));
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 2);
        assertEq(reputation.recoveredByService(serviceId), 2);
    }

    function test_aLaterRefundLeavesTheRecoveryInPlace() public {
        _attestRecovery(providerWallet, providerWallet, FAILED, EVIDENCE);
        bytes memory recorded = _recovery(FAILED);
        _refund(_refundPermit(FAILED, 40e6));
        assertEq(reputation.refundedAmount(FAILED), 40e6);
        assertEq(_recovery(FAILED), recorded);
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 1);
        assertEq(reputation.recoveredByService(serviceId), 1);
    }

    // ------------------------------------------------------------------
    // Refusals, in the order the resolver checks them
    // ------------------------------------------------------------------

    function test_refusedWhileSubmissionsAreDisabled() public {
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(false);
        _assertRefused(FAILED, _error(ReputationStorageBase.RecoverySubmissionsDisabled.selector), _valid(FAILED));
    }

    function test_revocableRecoveryIsRefusedByEASAndByTheResolver() public {
        // EAS refuses a revocable attestation under the irrevocable schema before the resolver runs.
        bytes memory before = _recoveryState(FAILED);
        vm.expectRevert(EAS_IRREVOCABLE);
        _attestAs(providerWallet, recoverySchema, providerWallet, true, bytes32(0), _valid(FAILED));
        assertEq(_recoveryState(FAILED), before);

        // The resolver refuses the same attestation on its own.
        Attestation memory item = _direct(providerWallet, providerWallet, _valid(FAILED));
        item.revocable = true;
        vm.prank(NATIVE_EAS);
        vm.expectRevert(ReputationStorageBase.InvalidRecoverySemantics.selector);
        reputation.attest(item);
        assertEq(_recoveryState(FAILED), before);
    }

    function test_refusesAReferenceToAnotherAttestation() public {
        bytes memory before = _recoveryState(FAILED);
        vm.expectRevert(ReputationStorageBase.InvalidRecoverySemantics.selector);
        _attestAs(providerWallet, recoverySchema, providerWallet, false, failedOutcomeUid, _valid(FAILED));
        assertEq(_recoveryState(FAILED), before);
    }

    function test_refusesAnyEncodingButTwoNonzeroWords() public {
        bytes memory valid = _valid(FAILED);
        bytes memory short = new bytes(63);
        for (uint256 i; i < short.length; ++i) {
            short[i] = valid[i];
        }
        bytes memory invalidEncoding = _error(ReputationStorageBase.InvalidRecoveryEncoding.selector);
        _assertRefused(FAILED, invalidEncoding, short);
        _assertRefused(FAILED, invalidEncoding, bytes.concat(valid, hex"00"));
        _assertRefused(FAILED, invalidEncoding, abi.encode(FAILED, EVIDENCE, EVIDENCE));
        _assertRefused(FAILED, invalidEncoding, abi.encode(FAILED, bytes32(0)));
    }

    function test_refusesUnknownAndIneligibleOrders() public {
        bytes32 unknown = keccak256("unknown-order");
        _assertRefused(unknown, _error(ReputationStorageBase.OrderNotRecorded.selector), _valid(unknown));

        bytes32 ineligible = keccak256("ineligible-order");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(ineligible);
        permit.reputationEligible = false;
        _register(permit);
        _assertRefused(
            ineligible, _error(ReputationStorageBase.OrderNotReputationEligible.selector), _valid(ineligible)
        );
    }

    function test_refusesOrdersWithoutAFailedOutcome() public {
        bytes memory requiresFailed = _error(ReputationStorageBase.RecoveryRequiresFailedOutcome.selector);
        bytes32 pending = keccak256("pending-order");
        _register(_permit(pending));
        _assertRefused(pending, requiresFailed, _valid(pending));

        bytes32 completed = keccak256("completed-order");
        _register(_permit(completed));
        _attestOutcome(completed, ReputationStorageBase.TransactionOutcome.Completed);
        _assertRefused(completed, requiresFailed, _valid(completed));

        bytes32 canceled = keccak256("canceled-order");
        _register(_permit(canceled));
        _attestOutcome(canceled, ReputationStorageBase.TransactionOutcome.Canceled);
        _assertRefused(canceled, requiresFailed, _valid(canceled));
    }

    function test_refusesASecondRecovery() public {
        _attestRecovery(providerWallet, providerWallet, FAILED, EVIDENCE);
        vm.warp(block.timestamp + 1);
        _assertRefused(
            FAILED,
            _error(ReputationStorageBase.RecoveryAlreadyRecorded.selector),
            abi.encode(FAILED, keccak256("other-evidence"))
        );
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 1);
    }

    function test_refusesARefundedOrder() public {
        _refund(_refundPermit(FAILED, 1));
        _assertRefused(FAILED, _error(ReputationStorageBase.RecoveryOfRefundedOrder.selector), _valid(FAILED));
    }

    function test_refusesAnyOtherAttesterOrRecipient() public {
        bytes memory notProvider = _error(ReputationStorageBase.NotOrderProvider.selector);
        _assertRefusedFrom(FAILED, notProvider, makeAddr("stranger"), providerWallet);
        _assertRefusedFrom(FAILED, notProvider, payer, providerWallet);
        _assertRefusedFrom(FAILED, notProvider, providerPayee, providerWallet);
        bytes memory wrongRecipient = _error(ReputationStorageBase.WrongReputationRecipient.selector);
        _assertRefusedFrom(FAILED, wrongRecipient, providerWallet, providerOwner);
        _assertRefusedFrom(FAILED, wrongRecipient, providerOwner, makeAddr("other-recipient"));
    }

    function test_refusesASanctionedAttesterOrRecipient() public {
        sanctions.setSanctioned(providerOwner, true);
        _assertRefusedFrom(
            FAILED,
            abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, providerOwner),
            providerOwner,
            providerWallet
        );
        sanctions.setSanctioned(providerOwner, false);
        sanctions.setSanctioned(providerWallet, true);
        _assertRefusedFrom(
            FAILED,
            abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, providerWallet),
            providerOwner,
            providerWallet
        );
    }

    function test_refusedWhileTheExternalDependencyIsPaused() public {
        vm.prank(admin);
        reputation.pauseExternalDependency();
        _assertRefused(FAILED, bytes("external dependency paused"), _valid(FAILED));
    }

    function test_checksRunInTheDocumentedOrder() public {
        bytes32 ineligible = keccak256("order-check-ineligible");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(ineligible);
        permit.reputationEligible = false;
        _register(permit);
        bytes32 pending = keccak256("order-check-pending");
        _register(_permit(pending));
        bytes32 refunded = _failedOrder("order-check-refunded");
        _refund(_refundPermit(refunded, 1));
        bytes32 clean = _failedOrder("order-check-clean");
        // FAILED is recovered first and refunded afterwards, so it fails two checks.
        _attestRecovery(providerWallet, providerWallet, FAILED, EVIDENCE);
        _refund(_refundPermit(FAILED, 1));

        address stranger = makeAddr("stranger");
        Attestation memory item = _direct(stranger, stranger, hex"00");
        item.revocable = true;
        item.refUID = failedOutcomeUid;
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(false);
        _expectDirectRefusal(item, ReputationStorageBase.RecoverySubmissionsDisabled.selector);
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(true);
        _expectDirectRefusal(item, ReputationStorageBase.InvalidRecoverySemantics.selector);
        item.revocable = false;
        _expectDirectRefusal(item, ReputationStorageBase.InvalidRecoverySemantics.selector);
        item.refUID = bytes32(0);
        _expectDirectRefusal(item, ReputationStorageBase.InvalidRecoveryEncoding.selector);
        item.data = abi.encode(keccak256("unknown-order"), bytes32(0));
        _expectDirectRefusal(item, ReputationStorageBase.InvalidRecoveryEncoding.selector);
        item.data = _valid(keccak256("unknown-order"));
        _expectDirectRefusal(item, ReputationStorageBase.OrderNotRecorded.selector);
        item.data = _valid(ineligible);
        _expectDirectRefusal(item, ReputationStorageBase.OrderNotReputationEligible.selector);
        item.data = _valid(pending);
        _expectDirectRefusal(item, ReputationStorageBase.RecoveryRequiresFailedOutcome.selector);
        item.data = _valid(FAILED);
        _expectDirectRefusal(item, ReputationStorageBase.RecoveryAlreadyRecorded.selector);
        item.data = _valid(refunded);
        _expectDirectRefusal(item, ReputationStorageBase.RecoveryOfRefundedOrder.selector);
        item.data = _valid(clean);
        _expectDirectRefusal(item, ReputationStorageBase.NotOrderProvider.selector);
        item.attester = providerWallet;
        _expectDirectRefusal(item, ReputationStorageBase.WrongReputationRecipient.selector);
        item.recipient = providerWallet;
        vm.prank(NATIVE_EAS);
        assertTrue(reputation.attest(item));
        assertEq(_recovery(clean), abi.encode(item.time, EVIDENCE, item.uid));
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 2);
        assertEq(reputation.recoveredByService(serviceId), 2);
    }

    // ------------------------------------------------------------------
    // Revocation
    // ------------------------------------------------------------------

    function test_aRecoveryCannotBeRevoked() public {
        bytes32 uid = _attestRecovery(providerWallet, providerWallet, FAILED, EVIDENCE);
        bytes memory recorded = _recoveryState(FAILED);
        vm.warp(block.timestamp + 1);

        vm.prank(providerWallet);
        vm.expectRevert(EAS_IRREVOCABLE);
        IEAS(NATIVE_EAS)
            .revoke(RevocationRequest({schema: recoverySchema, data: RevocationRequestData({uid: uid, value: 0})}));

        Attestation memory revoked = IEAS(NATIVE_EAS).getAttestation(uid);
        revoked.revocationTime = uint64(block.timestamp);
        vm.prank(NATIVE_EAS);
        vm.expectRevert(ReputationStorageBase.OutcomeNotRevocable.selector);
        reputation.revoke(revoked);

        assertEq(IEAS(NATIVE_EAS).getAttestation(uid).revocationTime, 0);
        assertEq(_recoveryState(FAILED), recorded);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_anyOtherDataLengthIsRefused(uint256 length) public {
        length = bound(length, 0, 160);
        vm.assume(length != 64);
        bytes memory valid = _valid(FAILED);
        bytes memory data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = i < valid.length ? valid[i] : bytes1(0x01);
        }
        _assertRefused(FAILED, _error(ReputationStorageBase.InvalidRecoveryEncoding.selector), data);
    }

    function testFuzz_onlyTheOrderProviderRecovers(address attester) public {
        assumeNotForgeAddress(attester);
        vm.assume(attester != providerOwner && attester != providerWallet);
        _assertRefusedFrom(FAILED, _error(ReputationStorageBase.NotOrderProvider.selector), attester, providerWallet);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _assertRecovered(address attester) private {
        SnapshotKeys memory keys = _keys(FAILED);
        bytes[] memory before = _getterResults(address(reputation), keys);
        bytes memory data = _valid(FAILED);
        bytes32 expectedUid = _expectedUid(recoverySchema, providerWallet, attester, false, bytes32(0), data);

        vm.expectEmit(true, true, true, true, address(reputation));
        emit ReputationStorageBase.OrderRecoveryRecorded(FAILED, PROVIDER_AGENT_ID, serviceId, EVIDENCE, expectedUid);
        bytes32 uid = _attestRecovery(attester, providerWallet, FAILED, EVIDENCE);

        assertEq(uid, expectedUid);
        (uint64 recoveredAt, bytes32 evidenceHash, bytes32 attestationUid) = reputation.getRecovery(FAILED);
        assertEq(recoveredAt, block.timestamp);
        assertEq(evidenceHash, EVIDENCE);
        assertEq(attestationUid, uid);
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 1);
        assertEq(reputation.recoveredByService(serviceId), 1);
        // The Failed outcome, its timing, every counter, total and refund stay as they were.
        _assertSameResults(before, _getterResults(address(reputation), keys));
    }

    function _assertRefused(bytes32 orderKey, bytes memory reason, bytes memory data) private {
        bytes memory before = _recoveryState(orderKey);
        vm.expectRevert(reason);
        _attestAs(providerWallet, recoverySchema, providerWallet, false, bytes32(0), data);
        assertEq(_recoveryState(orderKey), before);
    }

    function _assertRefusedFrom(bytes32 orderKey, bytes memory reason, address attester, address recipient) private {
        bytes memory before = _recoveryState(orderKey);
        vm.expectRevert(reason);
        _attestRecovery(attester, recipient, orderKey, EVIDENCE);
        assertEq(_recoveryState(orderKey), before);
    }

    function _expectDirectRefusal(Attestation memory item, bytes4 selector) private {
        bytes memory before = _recoveryState(FAILED);
        vm.prank(NATIVE_EAS);
        vm.expectRevert(selector);
        reputation.attest(item);
        assertEq(_recoveryState(FAILED), before);
    }

    /// The recovery record of `orderKey` and both recovery counters of the default provider and service.
    function _recoveryState(bytes32 orderKey) private view returns (bytes memory) {
        return abi.encode(
            _recovery(orderKey), reputation.recoveredCount(PROVIDER_AGENT_ID), reputation.recoveredByService(serviceId)
        );
    }

    /// An EAS-shaped recovery attestation delivered straight to the resolver.
    function _direct(address attester, address recipient, bytes memory data) private view returns (Attestation memory) {
        return Attestation({
            uid: keccak256(abi.encode("direct-recovery", data)),
            schema: recoverySchema,
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: 0,
            refUID: bytes32(0),
            recipient: recipient,
            attester: attester,
            revocable: false,
            data: data
        });
    }

    function _recoveryRequest(bytes32 orderKey, bytes32 evidenceHash)
        private
        view
        returns (AttestationRequestData memory)
    {
        return AttestationRequestData({
            recipient: providerWallet,
            expirationTime: 0,
            revocable: false,
            refUID: bytes32(0),
            data: abi.encode(orderKey, evidenceHash),
            value: 0
        });
    }

    function _failedOrder(string memory label) private returns (bytes32 orderKey) {
        orderKey = keccak256(bytes(label));
        _register(_permit(orderKey));
        _attestOutcome(orderKey, ReputationStorageBase.TransactionOutcome.Failed);
    }

    function _keys(bytes32 orderKey) private view returns (SnapshotKeys memory keys) {
        keys.orders = new bytes32[](1);
        keys.orders[0] = orderKey;
        keys.authorizations = new bytes32[](1);
        keys.authorizations[0] = reputation.getRecord(orderKey).authorizationKey;
        keys.confirmationUids = new bytes32[](0);
        keys.providers = new uint256[](1);
        keys.providers[0] = PROVIDER_AGENT_ID;
        keys.services = new bytes32[](1);
        keys.services[0] = serviceId;
        keys.payers = new address[](1);
        keys.payers[0] = payer;
    }

    function _valid(bytes32 orderKey) private pure returns (bytes memory) {
        return abi.encode(orderKey, EVIDENCE);
    }

    function _notRecovered() private pure returns (bytes memory) {
        return abi.encode(uint64(0), bytes32(0), bytes32(0));
    }

    function _error(bytes4 selector) private pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }
}

contract EASLegacy101RecoveryTest is ReputationRecoveryTest {
    function _legacy() internal pure override returns (bool) {
        return true;
    }
}

contract EASDeadline120RecoveryTest is ReputationRecoveryTest {
    function _legacy() internal pure override returns (bool) {
        return false;
    }
}
