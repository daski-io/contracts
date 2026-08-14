// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {Attestation} from "../src/interfaces/IEAS.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationStorageTest is ReputationTestBase {
    function test_registersSignedStandardOrderAndAggregatesByWallet() public {
        bytes32 orderKey = keccak256("ord_00000000-0000-4000-8000-000000000001");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(orderKey);
        _register(permit);

        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(record.authorizationKey, permit.authorizationKey);
        assertEq(record.payer, payer);
        assertEq(record.providerIdentitySnapshotHash, permit.providerIdentitySnapshotHash);
        (,,,,, uint256 providerTransactions) = reputation.getProviderStats(PROVIDER_AGENT_ID);
        assertEq(providerTransactions, 1);
        (uint256 buyerTransactions,,) = reputation.getBuyerStats(payer);
        assertEq(buyerTransactions, 1);
        assertEq(reputation.totalPaidByPayer(payer), 100e6);
    }

    function test_rejectsSignatureReplayAndSnapshotTampering() public {
        bytes32 orderKey = keccak256("order-replay");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(orderKey);
        _register(permit);

        bytes32 digest = reputation.orderDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);
        vm.expectRevert("order already recorded");
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));

        permit.orderKey = keccak256("changed-order");
        permit.authorizationKey = keccak256("changed-authorization");
        permit.providerIdentitySnapshotHash = bytes32(uint256(1));
        digest = reputation.orderDigest(permit);
        (v, r, s) = vm.sign(ORDER_SIGNER_KEY, digest);
        vm.expectRevert("snapshot hash mismatch");
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));
    }

    function test_rejectsExpiredInvalidAndSanctionedOrderPermits() public {
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(keccak256("expired"));
        permit.validBefore = uint64(block.timestamp - 1);
        bytes32 digest = reputation.orderDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);
        vm.expectRevert("order permit expired");
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));

        permit = _permit(keccak256("bad-signer"));
        digest = reputation.orderDigest(permit);
        (v, r, s) = vm.sign(0xB0B, digest);
        vm.expectRevert("invalid order signature");
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));

        permit = _permit(keccak256("sanctioned"));
        sanctions.setSanctioned(payer, true);
        digest = reputation.orderDigest(permit);
        (v, r, s) = vm.sign(ORDER_SIGNER_KEY, digest);
        vm.expectRevert();
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));
    }

    function test_recordsProviderOutcomeAndRejectsDuplicate() public {
        bytes32 orderKey = keccak256("outcome-order");
        _register(_permit(orderKey));
        Attestation memory outcome =
            _attestation(keccak256("outcome-uid"), outcomeSchema, providerWallet, orderKey, 0, false, bytes32(0));

        vm.prank(address(eas));
        assertTrue(reputation.attest(outcome));
        (uint256 completed,,,,,) = reputation.getProviderStats(PROVIDER_AGENT_ID);
        assertEq(completed, 1);

        outcome.uid = keccak256("duplicate-outcome");
        vm.prank(address(eas));
        vm.expectRevert("outcome already recorded");
        reputation.attest(outcome);
    }

    function test_confirmationRevisionRevocationAndTransitionCap() public {
        bytes32 orderKey = keccak256("confirmation-order");
        _register(_permit(orderKey));
        bytes32 firstUid = keccak256("confirmation-one");
        Attestation memory first = _attestation(firstUid, confirmationSchema, payer, orderKey, 1, true, bytes32(0));
        vm.prank(address(eas));
        reputation.attest(first);

        bytes32 secondUid = keccak256("confirmation-two");
        Attestation memory second = _attestation(secondUid, confirmationSchema, payer, orderKey, 2, true, firstUid);
        vm.prank(address(eas));
        reputation.attest(second);
        (, uint256 confirmed, uint256 notConfirmed) = reputation.getBuyerStats(payer);
        assertEq(confirmed, 0);
        assertEq(notConfirmed, 1);

        second.revocationTime = uint64(block.timestamp);
        vm.prank(address(eas));
        reputation.revoke(second);
        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
        assertEq(uint8(record.confirmation), uint8(ReputationStorageBase.BuyerConfirmation.Pending));
        assertEq(record.confirmationTransitions, 3);

        Attestation memory fourth =
            _attestation(keccak256("confirmation-four"), confirmationSchema, payer, orderKey, 1, true, bytes32(0));
        vm.prank(address(eas));
        vm.expectRevert("confirmation transition cap");
        reputation.attest(fourth);
    }

    function test_refundIsSignedMonotonicAndCappedAtGross() public {
        bytes32 orderKey = keccak256("refund-order");
        ReputationStorageBase.StandardReputationOrderV1 memory order = _permit(orderKey);
        _register(order);
        ReputationStorageBase.StandardReputationRefundV1 memory refund = ReputationStorageBase.StandardReputationRefundV1({
            orderKey: orderKey,
            authorizationKey: order.authorizationKey,
            cumulativeRefundedAmount: 20e6,
            refundEvidenceHash: keccak256("refund-one"),
            validBefore: uint64(block.timestamp + 5 minutes)
        });
        _refund(refund);
        assertEq(reputation.refundedAmount(orderKey), 20e6);
        assertEq(reputation.refundedAmountByPayer(payer), 20e6);

        bytes memory signature = _refundSignature(refund);
        vm.expectRevert("refund not monotonic");
        reputation.recordRefund(refund, signature);
        refund.cumulativeRefundedAmount = 101e6;
        refund.refundEvidenceHash = keccak256("refund-two");
        signature = _refundSignature(refund);
        vm.expectRevert("refund exceeds gross");
        reputation.recordRefund(refund, signature);
    }
}
