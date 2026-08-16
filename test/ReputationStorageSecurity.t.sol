// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "../src/interfaces/IEAS.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationStorageSecurityTest is ReputationTestBase {
    function test_typehashesMatchIndependentGoldenVectors() public view {
        assertEq(reputation.ORDER_TYPEHASH(), 0x687c38759e553277de2157d04bcb5bee98a121ac0e4b9e3575866a768bb8d2ea);
        assertEq(reputation.REFUND_TYPEHASH(), 0xee5b62c3e934195a045134fcc68f571ba421a01fd35504334bcc365ec392fa6c);
        assertEq(
            reputation.PROVIDER_IDENTITY_SNAPSHOT_V1_TYPEHASH(),
            0xdbe9ab91d93e0c204609996623e649314ec7ddae5e564edbcfedc2bac2332915
        );
        string memory vectors = vm.readFile("test/vectors/managed-marketplace-v1.json");
        assertEq(reputation.ORDER_TYPEHASH(), vm.parseJsonBytes32(vectors, ".typeHashes.standardReputationOrderV1"));
        assertEq(reputation.REFUND_TYPEHASH(), vm.parseJsonBytes32(vectors, ".typeHashes.standardReputationRefundV1"));
        assertEq(
            reputation.PROVIDER_IDENTITY_SNAPSHOT_V1_TYPEHASH(),
            vm.parseJsonBytes32(vectors, ".typeHashes.providerIdentitySnapshotV1")
        );
    }

    function test_rejectsWrongCanonicalTokenAndZeroEvidence() public {
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(keccak256("wrong-token"));
        permit.canonicalToken = makeAddr("other-token");
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.PaymentTokenMismatch.selector));

        permit = _permit(keccak256("zero-listing"));
        permit.listingManifestHash = bytes32(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroEvidenceHash.selector));
    }

    function test_orderSignerCannotBecomeAdminThroughEitherRotationOrder() public {
        address signer = vm.addr(ORDER_SIGNER_KEY);
        vm.prank(admin);
        vm.expectRevert(ReputationStorageBase.AdminCannotBeOrderSigner.selector);
        reputation.transferAdmin(signer);

        address candidate = makeAddr("candidate-admin");
        vm.prank(admin);
        reputation.transferAdmin(candidate);
        vm.prank(admin);
        vm.expectRevert(ReputationStorageBase.InvalidOrderSigner.selector);
        reputation.setOrderSigner(candidate);
    }

    function test_dependencyPauseCoversEasAndSignedWrites() public {
        bytes32 orderKey = keccak256("paused");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(orderKey);
        vm.prank(admin);
        reputation.pauseExternalDependency();
        _expectOrderRevert(permit, "external dependency paused");

        Attestation memory outcome =
            _attestation(keccak256("paused-outcome"), outcomeSchema, providerWallet, orderKey, 0, false, bytes32(0));
        vm.prank(address(eas));
        vm.expectRevert("external dependency paused");
        reputation.attest(outcome);
    }

    function test_batchRejectsLengthMismatchAndNonzeroValues() public {
        Attestation[] memory items = new Attestation[](1);
        items[0] =
            _attestation(keccak256("batch"), outcomeSchema, providerWallet, bytes32(uint256(1)), 0, false, bytes32(0));
        uint256[] memory values = new uint256[](0);
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.InvalidBatchValues.selector);
        reputation.multiAttest(items, values);

        values = new uint256[](1);
        values[0] = 1;
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.ValueUnsupported.selector);
        reputation.multiAttest(items, values);
    }

    function test_batchAttestAndRevokeMaintainPerItemCounters() public {
        bytes32 firstKey = keccak256("batch-one");
        bytes32 secondKey = keccak256("batch-two");
        _register(_permit(firstKey));
        _register(_permit(secondKey));
        Attestation[] memory items = new Attestation[](2);
        items[0] =
            _attestation(keccak256("batch-confirm-one"), confirmationSchema, payer, firstKey, 1, true, bytes32(0));
        items[1] =
            _attestation(keccak256("batch-confirm-two"), confirmationSchema, payer, secondKey, 2, true, bytes32(0));
        uint256[] memory values = new uint256[](2);
        vm.prank(address(eas));
        reputation.multiAttest(items, values);
        (, uint256 confirmed, uint256 notConfirmed) = reputation.getBuyerStats(payer);
        assertEq(confirmed, 1);
        assertEq(notConfirmed, 1);

        items[0].revocationTime = uint64(block.timestamp);
        items[1].revocationTime = uint64(block.timestamp);
        vm.prank(address(eas));
        reputation.multiRevoke(items, values);
        (, confirmed, notConfirmed) = reputation.getBuyerStats(payer);
        assertEq(confirmed, 0);
        assertEq(notConfirmed, 0);
    }

    function test_attestRejectsWrongAttesterRecipientAndTimeSemantics() public {
        bytes32 orderKey = keccak256("bad-attestation");
        _register(_permit(orderKey));
        Attestation memory item = _attestation(
            keccak256("bad-attester"), outcomeSchema, makeAddr("stranger"), orderKey, 0, false, bytes32(0)
        );
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.NotOrderProvider.selector);
        reputation.attest(item);

        item.attester = providerWallet;
        item.recipient = makeAddr("wrong-recipient");
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.WrongReputationRecipient.selector);
        reputation.attest(item);

        item.recipient = providerWallet;
        item.expirationTime = 1;
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.InvalidAttestationTime.selector);
        reputation.attest(item);
    }

    function test_ineligibleOrderStoresEvidenceWithoutPublicCountersOrAttestations() public {
        bytes32 orderKey = keccak256("ineligible");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(orderKey);
        permit.reputationEligible = false;
        _register(permit);
        (,,,,, uint256 count) = reputation.getProviderStats(PROVIDER_AGENT_ID);
        assertEq(count, 0);
        Attestation memory item = _attestation(
            keccak256("ineligible-outcome"), outcomeSchema, providerWallet, orderKey, 0, false, bytes32(0)
        );
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.OrderNotReputationEligible.selector);
        reputation.attest(item);
    }

    function test_registryAndServiceChangesInvalidateUnregisteredPermit() public {
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(keccak256("registry-change"));
        providers.setRegistered(PROVIDER_AGENT_ID, false);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ProviderNotRegistered.selector));

        providers.setRegistered(PROVIDER_AGENT_ID, true);
        permit = _permit(keccak256("service-change"));
        services.setService(serviceId, PROVIDER_AGENT_ID + 1);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ServiceMismatch.selector));
    }

    function test_refundRejectsExpiredWrongAuthorizationZeroEvidenceAndBadSigner() public {
        bytes32 orderKey = keccak256("refund-negatives");
        ReputationStorageBase.StandardReputationOrderV1 memory order = _permit(orderKey);
        _register(order);
        ReputationStorageBase.StandardReputationRefundV1 memory refund = ReputationStorageBase.StandardReputationRefundV1({
            orderKey: orderKey,
            authorizationKey: bytes32(uint256(1)),
            cumulativeRefundedAmount: 1,
            refundEvidenceHash: keccak256("refund"),
            validBefore: uint64(block.timestamp + 1)
        });
        _expectRefundRevert(refund, abi.encodeWithSelector(ReputationStorageBase.AuthorizationMismatch.selector));
        refund.authorizationKey = order.authorizationKey;
        refund.refundEvidenceHash = bytes32(0);
        _expectRefundRevert(refund, abi.encodeWithSelector(ReputationStorageBase.ZeroRefundEvidence.selector));
        refund.refundEvidenceHash = keccak256("refund");
        vm.warp(block.timestamp + 2);
        _expectRefundRevert(refund, abi.encodeWithSelector(ReputationStorageBase.RefundPermitExpired.selector));
    }

    function test_sanctionsAreRecheckedForAttestationAndRevocation() public {
        bytes32 orderKey = keccak256("sanctions-attest");
        _register(_permit(orderKey));
        sanctions.setSanctioned(providerWallet, true);
        Attestation memory outcome = _attestation(
            keccak256("sanctioned-outcome"), outcomeSchema, providerWallet, orderKey, 0, false, bytes32(0)
        );
        vm.prank(address(eas));
        vm.expectRevert();
        reputation.attest(outcome);

        sanctions.setSanctioned(providerWallet, false);
        Attestation memory confirmation =
            _attestation(keccak256("sanctioned-revoke"), confirmationSchema, payer, orderKey, 1, true, bytes32(0));
        vm.prank(address(eas));
        reputation.attest(confirmation);
        sanctions.setSanctioned(payer, true);
        confirmation.revocationTime = uint64(block.timestamp);
        vm.prank(address(eas));
        vm.expectRevert();
        reputation.revoke(confirmation);
    }

    function test_valueWeightUsesLogarithmicGrossAmountBuckets() public {
        ReputationStorageBase.StandardReputationOrderV1 memory small = _permit(keccak256("small"));
        small.grossAmount = 250_000;
        _register(small);
        ReputationStorageBase.StandardReputationOrderV1 memory large = _permit(keccak256("large"));
        large.grossAmount = 2_000_000;
        _register(large);
        vm.startPrank(address(eas));
        reputation.attest(
            _attestation(keccak256("small-confirm"), confirmationSchema, payer, small.orderKey, 1, true, bytes32(0))
        );
        reputation.attest(
            _attestation(keccak256("large-confirm"), confirmationSchema, payer, large.orderKey, 1, true, bytes32(0))
        );
        vm.stopPrank();
        assertEq(reputation.confirmedWeightByProvider(PROVIDER_AGENT_ID), 5);
    }

    function testFuzz_orderAccountingPreservesBoundedGrossAmount(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000_000_000_000_000_000_000);
        ReputationStorageBase.StandardReputationOrderV1 memory permit =
            _permit(keccak256(abi.encode("fuzz-order", amount)));
        permit.grossAmount = amount;
        _register(permit);

        assertEq(reputation.totalPaidByPayer(payer), amount);
        (,,,,, uint256 count) = reputation.getProviderStats(PROVIDER_AGENT_ID);
        assertEq(count, 1);
    }

    function _expectOrderRevert(ReputationStorageBase.StandardReputationOrderV1 memory permit, bytes memory revertData)
        private
    {
        bytes32 digest = reputation.orderDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);
        vm.expectRevert(revertData);
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));
    }

    function _expectRefundRevert(
        ReputationStorageBase.StandardReputationRefundV1 memory permit,
        bytes memory revertData
    ) private {
        bytes memory signature = _refundSignature(permit);
        vm.expectRevert(revertData);
        reputation.recordRefund(permit, signature);
    }
}
