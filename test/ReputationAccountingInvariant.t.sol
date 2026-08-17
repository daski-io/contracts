// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationConfirmationHandler is Test {
    ReputationStorage private immutable _reputation;
    MockEAS private immutable _eas;
    bytes32 private immutable _schema;
    bytes32 private immutable _orderKey;
    address private immutable _payer;
    address private immutable _recipient;

    bytes32 public currentUid;
    uint8 public currentConfirmation;
    uint8 public successfulSubmissions;
    bytes32[] private _submittedUids;

    constructor(
        ReputationStorage reputation,
        MockEAS eas,
        bytes32 schema,
        bytes32 orderKey,
        address payer,
        address recipient
    ) {
        _reputation = reputation;
        _eas = eas;
        _schema = schema;
        _orderKey = orderKey;
        _payer = payer;
        _recipient = recipient;
    }

    function submit(uint8 seed) external {
        if (successfulSubmissions >= _reputation.MAX_CONFIRMATION_SUBMISSIONS()) return;
        uint8 confirmation = (seed % 2) + 1;
        AttestationRequest memory request = AttestationRequest({
            schema: _schema,
            data: AttestationRequestData({
                recipient: _recipient,
                expirationTime: 0,
                revocable: true,
                refUID: currentUid,
                data: abi.encode(_orderKey, confirmation),
                value: 0
            })
        });
        vm.prank(_payer);
        bytes32 uid = _eas.attest(request);
        currentUid = uid;
        currentConfirmation = confirmation;
        successfulSubmissions++;
        _submittedUids.push(uid);
    }

    function revoke() external {
        if (currentUid == bytes32(0)) return;
        _revoke(currentUid);
        currentUid = bytes32(0);
        currentConfirmation = 0;
    }

    function revokeStale(uint256 seed) external {
        uint256 count = _submittedUids.length;
        if (count == 0) return;
        bytes32 uid = _submittedUids[seed % count];
        if (uid == currentUid) return;
        Attestation memory item = _eas.getAttestation(uid);
        if (item.revocationTime != 0) return;
        _revoke(uid);
    }

    function submittedUidCount() external view returns (uint256) {
        return _submittedUids.length;
    }

    function submittedUid(uint256 index) external view returns (bytes32) {
        return _submittedUids[index];
    }

    function _revoke(bytes32 uid) private {
        RevocationRequest memory request =
            RevocationRequest({schema: _schema, data: RevocationRequestData({uid: uid, value: 0})});
        vm.prank(_payer);
        _eas.revoke(request);
    }
}

contract ReputationAccountingInvariantTest is StdInvariant, ReputationTestBase {
    bytes32 private constant ORDER_KEY = keccak256("stateful-confirmation-order");

    ReputationConfirmationHandler private _handler;

    function setUp() public override {
        super.setUp();
        _register(_permit(ORDER_KEY));
        _handler =
            new ReputationConfirmationHandler(reputation, eas, confirmationSchema, ORDER_KEY, payer, providerWallet);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ReputationConfirmationHandler.submit.selector;
        selectors[1] = ReputationConfirmationHandler.revoke.selector;
        selectors[2] = ReputationConfirmationHandler.revokeStale.selector;
        targetSelector(FuzzSelector({addr: address(_handler), selectors: selectors}));
        targetContract(address(_handler));
    }

    function invariant_confirmationAccountingRemainsSingleValued() public view {
        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(ORDER_KEY);
        uint256 providerConfirmed = reputation.confirmedCount(PROVIDER_AGENT_ID);
        uint256 providerRejected = reputation.notConfirmedCount(PROVIDER_AGENT_ID);
        uint256 serviceConfirmed = reputation.confirmedByService(serviceId);
        uint256 serviceRejected = reputation.notConfirmedByService(serviceId);
        uint256 buyerConfirmed = reputation.payerConfirmedCount(payer);
        uint256 buyerRejected = reputation.payerNotConfirmedCount(payer);

        assertLe(record.confirmationSubmissions, reputation.MAX_CONFIRMATION_SUBMISSIONS());
        assertEq(record.confirmationSubmissions, _handler.successfulSubmissions());
        assertEq(providerConfirmed, serviceConfirmed);
        assertEq(providerConfirmed, buyerConfirmed);
        assertEq(providerRejected, serviceRejected);
        assertEq(providerRejected, buyerRejected);
        assertLe(providerConfirmed + providerRejected, 1);

        if (record.confirmation == ReputationStorageBase.BuyerConfirmation.Pending) {
            assertEq(record.currentConfirmationUid, bytes32(0));
            assertEq(record.confirmationTimestamp, 0);
            assertEq(providerConfirmed + providerRejected, 0);
        } else {
            assertEq(record.currentConfirmationUid, _handler.currentUid());
            assertTrue(record.currentConfirmationUid != bytes32(0));
            assertEq(providerConfirmed + providerRejected, 1);
        }
    }

    function invariant_onlyCurrentConfirmationUidIsIndexed() public view {
        bytes32 currentUid = _handler.currentUid();
        uint256 count = _handler.submittedUidCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 uid = _handler.submittedUid(i);
            if (uid == currentUid) {
                assertEq(reputation.orderKeyByConfirmationUid(uid), ORDER_KEY);
                assertEq(uint8(reputation.confirmationByUid(uid)), _handler.currentConfirmation());
            } else {
                assertEq(reputation.orderKeyByConfirmationUid(uid), bytes32(0));
                assertEq(uint8(reputation.confirmationByUid(uid)), 0);
            }
        }
    }
}
