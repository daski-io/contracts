// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "../src/interfaces/IEAS.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationStorageNegativeMatrixTest is ReputationTestBase {
    function test_rejectsEveryZeroOrderFieldClass() public {
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(keccak256("zero-order"));
        permit.orderKey = bytes32(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroOrderIdentifier.selector));

        permit = _permit(keccak256("zero-authorization"));
        permit.authorizationKey = bytes32(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroOrderIdentifier.selector));

        permit = _permit(keccak256("zero-provider"));
        permit.providerAgentId = 0;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroProviderOrService.selector));

        permit = _permit(keccak256("zero-service"));
        permit.serviceId = bytes32(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroProviderOrService.selector));

        permit = _permit(keccak256("zero-payer"));
        permit.payer = address(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroParticipant.selector));

        permit = _permit(keccak256("zero-owner"));
        permit.providerOwner = address(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroParticipant.selector));

        permit = _permit(keccak256("zero-agent-wallet"));
        permit.providerAgentWallet = address(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroParticipant.selector));

        permit = _permit(keccak256("zero-payee"));
        permit.providerPayee = address(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.PaymentTokenMismatch.selector));

        permit = _permit(keccak256("zero-gross"));
        permit.grossAmount = 0;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.InvalidPaymentFacts.selector));

        permit = _permit(keccak256("zero-paid-at"));
        permit.paidAt = 0;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.InvalidPaymentFacts.selector));

        permit = _permit(keccak256("zero-block"));
        permit.blockNumber = 0;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.InvalidSnapshotBlock.selector));

        permit = _permit(keccak256("zero-block-hash"));
        permit.blockHash = bytes32(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroSnapshotBlockHash.selector));

        permit = _permit(keccak256("zero-release"));
        permit.releaseEvidenceHash = bytes32(0);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ZeroEvidenceHash.selector));
    }

    function test_rejectsSelfPurchasesForEveryProviderRole() public {
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(keccak256("owner-self"));
        permit.payer = permit.providerOwner;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ProviderSelfPurchase.selector));

        permit = _permit(keccak256("wallet-self"));
        permit.payer = permit.providerAgentWallet;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ProviderSelfPurchase.selector));

        permit = _permit(keccak256("payee-self"));
        permit.payer = permit.providerPayee;
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ProviderSelfPurchase.selector));
    }

    function test_rejectsEveryRegistryAddressMismatch() public {
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(keccak256("identity-registry"));
        permit.identityRegistry = makeAddr("other-identity");
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.IdentityRegistryMismatch.selector));

        permit = _permit(keccak256("provider-registry"));
        permit.providerRegistry = makeAddr("other-provider-registry");
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ProviderRegistryMismatch.selector));

        permit = _permit(keccak256("service-registry"));
        permit.serviceRegistry = makeAddr("other-service-registry");
        permit.providerIdentitySnapshotHash = reputation.providerIdentitySnapshotHash(permit);
        _expectOrderRevert(permit, abi.encodeWithSelector(ReputationStorageBase.ServiceRegistryMismatch.selector));
    }

    function test_rejectsWrongRuntimeAttestationRevocability() public {
        bytes32 orderKey = keccak256("revocability");
        _register(_permit(orderKey));
        Attestation memory outcome =
            _attestation(keccak256("revocable-outcome"), outcomeSchema, providerWallet, orderKey, 0, true, bytes32(0));
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.InvalidOutcomeSemantics.selector);
        reputation.attest(outcome);

        Attestation memory confirmation =
            _attestation(keccak256("fixed-confirmation"), confirmationSchema, payer, orderKey, 1, false, bytes32(0));
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.ConfirmationMustBeRevocable.selector);
        reputation.attest(confirmation);
    }

    function test_revokeRejectsWrongSchemaTimeFlagPayerRecipientAndValue() public {
        bytes32 orderKey = keccak256("revoke-negatives");
        _register(_permit(orderKey));
        Attestation memory confirmation = _activeConfirmation(orderKey);
        vm.prank(address(eas));
        reputation.attest(confirmation);
        confirmation.revocationTime = uint64(block.timestamp);

        Attestation memory invalid = _activeConfirmation(orderKey);
        invalid.revocationTime = uint64(block.timestamp);
        invalid.schema = outcomeSchema;
        _expectRevokeRevert(invalid, abi.encodeWithSelector(ReputationStorageBase.OutcomeNotRevocable.selector));

        invalid = _activeConfirmation(orderKey);
        invalid.revocationTime = uint64(block.timestamp);
        invalid.expirationTime = 1;
        _expectRevokeRevert(invalid, abi.encodeWithSelector(ReputationStorageBase.InvalidRevocation.selector));

        invalid = _activeConfirmation(orderKey);
        invalid.revocationTime = uint64(block.timestamp);
        invalid.revocable = false;
        _expectRevokeRevert(invalid, abi.encodeWithSelector(ReputationStorageBase.InvalidRevocation.selector));

        invalid = _activeConfirmation(orderKey);
        invalid.revocationTime = uint64(block.timestamp);
        invalid.attester = makeAddr("wrong-payer");
        _expectRevokeRevert(invalid, abi.encodeWithSelector(ReputationStorageBase.NotOrderPayer.selector));

        invalid = _activeConfirmation(orderKey);
        invalid.revocationTime = uint64(block.timestamp);
        invalid.recipient = makeAddr("wrong-recipient");
        _expectRevokeRevert(invalid, abi.encodeWithSelector(ReputationStorageBase.WrongReputationRecipient.selector));

        vm.deal(address(eas), 1);
        vm.prank(address(eas));
        vm.expectRevert(ReputationStorageBase.ValueUnsupported.selector);
        reputation.revoke{value: 1}(confirmation);
    }

    function _activeConfirmation(bytes32 orderKey) private view returns (Attestation memory) {
        return _attestation(keccak256("active-confirmation"), confirmationSchema, payer, orderKey, 1, true, bytes32(0));
    }

    function _expectOrderRevert(ReputationStorageBase.StandardReputationOrderV1 memory permit, bytes memory revertData)
        private
    {
        bytes32 digest = reputation.orderDigest(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORDER_SIGNER_KEY, digest);
        vm.expectRevert(revertData);
        reputation.registerOrder(permit, abi.encodePacked(r, s, v));
    }

    function _expectRevokeRevert(Attestation memory item, bytes memory revertData) private {
        vm.prank(address(eas));
        vm.expectRevert(revertData);
        reputation.revoke(item);
    }
}
