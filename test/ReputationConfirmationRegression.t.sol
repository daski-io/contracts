// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "../src/interfaces/IEAS.sol";
import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationConfirmationRegressionTest is ReputationTestBase {
    function test_mixedStaleAndCurrentBatchRevokeOnlyClearsCurrent() public {
        bytes32 orderKey = keccak256("mixed-batch-revoke");
        _register(_permit(orderKey));

        Attestation memory first =
            _attestation(keccak256("first"), confirmationSchema, payer, orderKey, 1, true, bytes32(0));
        vm.prank(address(eas));
        reputation.attest(first);

        Attestation memory second =
            _attestation(keccak256("second"), confirmationSchema, payer, orderKey, 2, true, first.uid);
        vm.prank(address(eas));
        reputation.attest(second);

        vm.warp(block.timestamp + 1);
        first.revocationTime = uint64(block.timestamp);
        second.revocationTime = uint64(block.timestamp);
        Attestation[] memory revocations = new Attestation[](2);
        revocations[0] = first;
        revocations[1] = second;

        vm.prank(address(eas));
        reputation.multiRevoke(revocations, new uint256[](2));

        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(record.currentConfirmationUid, bytes32(0));
        assertEq(uint8(record.confirmation), uint8(ReputationStorageBase.BuyerConfirmation.Pending));
        assertEq(record.confirmationSubmissions, 2);
        assertEq(reputation.confirmedCount(PROVIDER_AGENT_ID), 0);
        assertEq(reputation.notConfirmedCount(PROVIDER_AGENT_ID), 0);
    }

    function test_revokeRejectsMalformedAndNonBinaryDataWithoutMutation() public {
        bytes32 orderKey = keccak256("invalid-revoke-data");
        _register(_permit(orderKey));
        Attestation memory current =
            _attestation(keccak256("current"), confirmationSchema, payer, orderKey, 1, true, bytes32(0));
        vm.prank(address(eas));
        reputation.attest(current);
        vm.warp(block.timestamp + 1);

        Attestation memory invalid = current;
        invalid.revocationTime = uint64(block.timestamp);
        invalid.data = hex"01";
        vm.prank(address(eas));
        vm.expectRevert();
        reputation.revoke(invalid);

        invalid.data = abi.encode(orderKey, uint8(3));
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.BinaryConfirmationOnly.selector);
        reputation.revoke(invalid);

        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(record.currentConfirmationUid, current.uid);
        assertEq(uint8(record.confirmation), uint8(ReputationStorageBase.BuyerConfirmation.Confirmed));
        assertEq(record.confirmationSubmissions, 1);
        assertEq(reputation.confirmedCount(PROVIDER_AGENT_ID), 1);
    }

    function test_revokeRejectsWrongPayerAndRecipientWithoutMutation() public {
        bytes32 orderKey = keccak256("wrong-revoker-or-recipient");
        _register(_permit(orderKey));
        Attestation memory current =
            _attestation(keccak256("current"), confirmationSchema, payer, orderKey, 1, true, bytes32(0));
        vm.prank(address(eas));
        reputation.attest(current);
        vm.warp(block.timestamp + 1);

        Attestation memory invalid = current;
        invalid.revocationTime = uint64(block.timestamp);
        invalid.attester = makeAddr("wrong-payer");
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.NotOrderPayer.selector);
        reputation.revoke(invalid);

        invalid.attester = payer;
        invalid.recipient = makeAddr("wrong-recipient");
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.WrongReputationRecipient.selector);
        reputation.revoke(invalid);

        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(record.currentConfirmationUid, current.uid);
        assertEq(reputation.confirmedCount(PROVIDER_AGENT_ID), 1);
    }

    function test_mockEASInvalidAttestationRollsBackAndValidAttestationCommits() public {
        bytes32 orderKey = keccak256("mock-eas-attest-atomicity");
        _register(_permit(orderKey));
        bytes32 predictedUid = keccak256(abi.encodePacked("attestation", uint256(1), confirmationSchema, payer));

        vm.expectRevert(ReputationStorageBase.BinaryConfirmationOnly.selector);
        _submitConfirmation(orderKey, 3, bytes32(0));

        assertFalse(eas.isAttestationValid(predictedUid));
        assertEq(reputation.getRecord(orderKey).confirmationSubmissions, 0);

        bytes32 committedUid = _submitConfirmation(orderKey, 1, bytes32(0));
        assertEq(committedUid, predictedUid);
        assertTrue(eas.isAttestationValid(committedUid));
        assertEq(reputation.getRecord(orderKey).currentConfirmationUid, committedUid);
    }

    function test_mockEASSanctionsRevertsRollBackAndValidRevokeCommits() public {
        bytes32 orderKey = keccak256("mock-eas-revoke-atomicity");
        _register(_permit(orderKey));
        bytes32 uid = _submitConfirmation(orderKey, 1, bytes32(0));
        vm.warp(block.timestamp + 1);

        sanctions.setSanctioned(payer, true);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, payer));
        _revokeConfirmation(uid);
        assertEq(eas.getAttestation(uid).revocationTime, 0);
        assertEq(reputation.getRecord(orderKey).currentConfirmationUid, uid);

        sanctions.setSanctioned(payer, false);
        sanctions.setSanctioned(providerWallet, true);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, providerWallet));
        _revokeConfirmation(uid);
        assertEq(eas.getAttestation(uid).revocationTime, 0);
        assertEq(reputation.getRecord(orderKey).currentConfirmationUid, uid);

        sanctions.setSanctioned(providerWallet, false);
        _revokeConfirmation(uid);
        assertGt(eas.getAttestation(uid).revocationTime, 0);
        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(record.currentConfirmationUid, bytes32(0));
        assertEq(uint8(record.confirmation), uint8(ReputationStorageBase.BuyerConfirmation.Pending));
        assertEq(record.confirmationSubmissions, 1);
        assertEq(reputation.confirmedCount(PROVIDER_AGENT_ID), 0);
    }
}
