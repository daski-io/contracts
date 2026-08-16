// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {Attestation} from "../src/interfaces/IEAS.sol";
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
    uint8 public successfulTransitions;
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
        if (successfulTransitions >= _reputation.MAX_CONFIRMATION_TRANSITIONS()) return;
        uint8 confirmation = (seed % 2) + 1;
        bytes32 uid = keccak256(abi.encode(successfulTransitions, confirmation, currentUid));
        Attestation memory item = _attestation(uid, confirmation, currentUid, 0);

        vm.prank(address(_eas));
        _reputation.attest(item);
        currentUid = uid;
        currentConfirmation = confirmation;
        successfulTransitions++;
        _submittedUids.push(uid);
    }

    function revoke() external {
        if (currentUid == bytes32(0) || successfulTransitions >= _reputation.MAX_CONFIRMATION_TRANSITIONS()) return;
        Attestation memory item = _attestation(currentUid, currentConfirmation, bytes32(0), uint64(block.timestamp));

        vm.prank(address(_eas));
        _reputation.revoke(item);
        currentUid = bytes32(0);
        currentConfirmation = 0;
        successfulTransitions++;
    }

    function submittedUidCount() external view returns (uint256) {
        return _submittedUids.length;
    }

    function submittedUid(uint256 index) external view returns (bytes32) {
        return _submittedUids[index];
    }

    function _attestation(bytes32 uid, uint8 confirmation, bytes32 refUid, uint64 revokedAt)
        private
        view
        returns (Attestation memory)
    {
        return Attestation({
            uid: uid,
            schema: _schema,
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: revokedAt,
            refUID: refUid,
            recipient: _recipient,
            attester: _payer,
            revocable: true,
            data: abi.encode(_orderKey, confirmation)
        });
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

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ReputationConfirmationHandler.submit.selector;
        selectors[1] = ReputationConfirmationHandler.revoke.selector;
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

        assertLe(record.confirmationTransitions, reputation.MAX_CONFIRMATION_TRANSITIONS());
        assertEq(record.confirmationTransitions, _handler.successfulTransitions());
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
