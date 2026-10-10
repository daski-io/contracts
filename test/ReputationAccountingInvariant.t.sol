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
    IEAS,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {NativeEASReputationTestBase} from "./helpers/NativeEASReputationTestBase.sol";
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

/// Random outcome, recovery, refund and enablement sequences over two providers
/// and three services, sent through the actual EAS runtime. Every recovery
/// attempt must be accepted exactly when the resolver's admission rules allow it.
contract ReputationRecoveryHandler is Test {
    address private constant NATIVE_EAS = 0x4200000000000000000000000000000000000021;

    ReputationStorage private immutable _reputation;
    bytes32 private immutable _outcomeSchema;
    bytes32 private immutable _recoverySchema;
    uint256 private immutable _signerKey;
    address private immutable _admin;
    address private immutable _guardian;
    bytes32[] private _orders;

    mapping(uint256 => uint256) public expectedRecoveredCount;
    mapping(bytes32 => uint256) public expectedRecoveredByService;
    uint256 public acceptedRecoveries;
    uint256 public refusedRecoveries;

    constructor(
        ReputationStorage reputation,
        bytes32 outcomeSchema,
        bytes32 recoverySchema,
        uint256 signerKey,
        address admin,
        address guardian,
        bytes32[] memory orders
    ) {
        _reputation = reputation;
        _outcomeSchema = outcomeSchema;
        _recoverySchema = recoverySchema;
        _signerKey = signerKey;
        _admin = admin;
        _guardian = guardian;
        _orders = orders;
    }

    /// Half of the recorded outcomes are Failed, the rest Completed or Canceled.
    function recordOutcome(uint256 orderSeed, uint8 outcomeSeed, bool byOwner) external {
        ReputationStorageBase.ReputationRecord memory record = _reputation.getRecord(_pick(orderSeed));
        if (record.orderKey == bytes32(0) || !record.reputationEligible || record.outcomeRecorded) return;
        uint8 outcome = outcomeSeed % 4 == 0 ? 0 : outcomeSeed % 4 == 1 ? 2 : 1;
        AttestationRequest memory request =
            _request(_outcomeSchema, record.providerAgentWallet, abi.encode(record.orderKey, outcome));
        vm.prank(byOwner ? record.providerOwner : record.providerAgentWallet);
        IEAS(NATIVE_EAS).attest(request);
    }

    /// Any order; one mode in four sends a zero evidence hash, another a stray recipient.
    function recover(uint256 orderSeed, uint8 mode) external {
        _recover(_pick(orderSeed), mode % 8 >= 4, mode % 4 == 0, mode % 4 == 1);
    }

    /// A well-formed recovery of the next Failed order not yet recovered, when there is one.
    function recoverFailedOrder(uint256 orderSeed, bool byOwner) external {
        bytes32 orderKey = _pick(orderSeed);
        uint256 start = orderSeed % _orders.length;
        for (uint256 i; i < _orders.length; ++i) {
            bytes32 candidate = _orders[(start + i) % _orders.length];
            ReputationStorageBase.ReputationRecord memory record = _reputation.getRecord(candidate);
            (uint64 recoveredAt,,) = _reputation.getRecovery(candidate);
            if (
                record.outcomeRecorded && record.outcome == ReputationStorageBase.TransactionOutcome.Failed
                    && recoveredAt == 0
            ) {
                orderKey = candidate;
                break;
            }
        }
        _recover(orderKey, byOwner, false, false);
    }

    function refund(uint256 orderSeed, uint256 amountSeed) external {
        bytes32 orderKey = _pick(orderSeed);
        ReputationStorageBase.ReputationRecord memory record = _reputation.getRecord(orderKey);
        uint256 previous = _reputation.refundedAmount(orderKey);
        if (record.orderKey == bytes32(0) || previous >= record.grossAmount) return;
        ReputationStorageBase.StandardReputationRefundV1 memory permit = ReputationStorageBase.StandardReputationRefundV1({
            orderKey: orderKey,
            authorizationKey: record.authorizationKey,
            cumulativeRefundedAmount: bound(amountSeed, previous + 1, record.grossAmount),
            refundEvidenceHash: keccak256(abi.encode("refund", orderKey, previous)),
            validBefore: uint64(block.timestamp + 5 minutes)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerKey, _reputation.refundDigest(permit));
        _reputation.recordRefund(permit, abi.encodePacked(r, s, v));
    }

    function switchSubmissions(bool enabled, bool byGuardian) external {
        if (!byGuardian) {
            vm.prank(_admin);
            _reputation.setRecoverySubmissionsEnabled(enabled);
            return;
        }
        vm.prank(_guardian);
        try _reputation.setRecoverySubmissionsEnabled(enabled) {
            assertFalse(enabled, "guardian enabled recovery submissions");
        } catch (bytes memory reason) {
            assertTrue(enabled, "guardian could not disable recovery submissions");
            assertEq(reason, abi.encodeWithSelector(ReputationStorageBase.RecoveryEnableRequiresAdmin.selector));
        }
    }

    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 7 days));
    }

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function orderAt(uint256 index) external view returns (bytes32) {
        return _orders[index];
    }

    function _recover(bytes32 orderKey, bool byOwner, bool zeroEvidence, bool strayRecipient) private {
        ReputationStorageBase.ReputationRecord memory record = _reputation.getRecord(orderKey);
        bool admissible = _admissible(orderKey, record) && !zeroEvidence && !strayRecipient;
        address attester = byOwner ? record.providerOwner : record.providerAgentWallet;
        address recipient = strayRecipient ? address(0xCAFE) : record.providerAgentWallet;
        bytes32 evidence = zeroEvidence ? bytes32(0) : keccak256(abi.encode(orderKey, block.timestamp));
        AttestationRequest memory request = _request(_recoverySchema, recipient, abi.encode(orderKey, evidence));
        vm.prank(attester == address(0) ? address(0xBEEF) : attester);
        try IEAS(NATIVE_EAS).attest(request) {
            assertTrue(admissible, "inadmissible recovery accepted");
            expectedRecoveredCount[record.providerAgentId]++;
            expectedRecoveredByService[record.serviceId]++;
            acceptedRecoveries++;
        } catch {
            assertFalse(admissible, "admissible recovery refused");
            refusedRecoveries++;
        }
    }

    function _admissible(bytes32 orderKey, ReputationStorageBase.ReputationRecord memory record)
        private
        view
        returns (bool)
    {
        (uint64 recoveredAt,,) = _reputation.getRecovery(orderKey);
        return _reputation.recoverySubmissionsEnabled() && record.reputationEligible && record.outcomeRecorded
            && record.outcome == ReputationStorageBase.TransactionOutcome.Failed && recoveredAt == 0
            && _reputation.refundedAmount(orderKey) == 0;
    }

    function _request(bytes32 schema, address recipient, bytes memory data)
        private
        pure
        returns (AttestationRequest memory)
    {
        return AttestationRequest({
            schema: schema,
            data: AttestationRequestData({
                recipient: recipient, expirationTime: 0, revocable: false, refUID: bytes32(0), data: data, value: 0
            })
        });
    }

    function _pick(uint256 seed) private view returns (bytes32) {
        return _orders[seed % _orders.length];
    }
}

contract ReputationRecoveryInvariantTest is StdInvariant, NativeEASReputationTestBase {
    ReputationRecoveryHandler private _handler;

    function _legacy() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        _deployRecoveryReady();
        vm.prank(admin);
        reputation.setPauseGuardian(makeAddr("pause-guardian"));

        bytes32[] memory orders = new bytes32[](11);
        for (uint256 i; i < 3; ++i) {
            string memory index = vm.toString(i);
            orders[i] = _order(string.concat("a1-", index), PROVIDER_AGENT_ID, serviceId, payer, 100e6, true);
            orders[3 + i] =
                _order(string.concat("a2-", index), PROVIDER_AGENT_ID, secondServiceId, secondPayer, 5e6, true);
            orders[6 + i] = _order(string.concat("b3-", index), SECOND_AGENT_ID, thirdServiceId, payer, 2e6, true);
        }
        orders[9] = _order("b3-ineligible", SECOND_AGENT_ID, thirdServiceId, secondPayer, 1e6, false);
        orders[10] = keccak256("unregistered-order");
        // Every run starts with one Failed and one Completed order per provider and service pair.
        for (uint256 i; i < 9; i += 3) {
            _attestOutcome(orders[i], ReputationStorageBase.TransactionOutcome.Failed);
            _attestOutcome(orders[i + 1], ReputationStorageBase.TransactionOutcome.Completed);
        }
        _handler = new ReputationRecoveryHandler(
            reputation, outcomeSchema, recoverySchema, ORDER_SIGNER_KEY, admin, makeAddr("pause-guardian"), orders
        );

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ReputationRecoveryHandler.recordOutcome.selector;
        selectors[1] = ReputationRecoveryHandler.recover.selector;
        selectors[2] = ReputationRecoveryHandler.recoverFailedOrder.selector;
        selectors[3] = ReputationRecoveryHandler.refund.selector;
        selectors[4] = ReputationRecoveryHandler.switchSubmissions.selector;
        selectors[5] = ReputationRecoveryHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(_handler), selectors: selectors}));
        targetContract(address(_handler));
    }

    function invariant_recoveriesNeverExceedFailures() public view {
        uint256[2] memory agents = [PROVIDER_AGENT_ID, SECOND_AGENT_ID];
        for (uint256 i; i < agents.length; ++i) {
            assertLe(reputation.recoveredCount(agents[i]), reputation.failedCount(agents[i]));
        }
        bytes32[3] memory serviceIds = [serviceId, secondServiceId, thirdServiceId];
        for (uint256 i; i < serviceIds.length; ++i) {
            assertLe(reputation.recoveredByService(serviceIds[i]), reputation.failedByService(serviceIds[i]));
        }
    }

    function invariant_recoveryCountersMatchTheRecoveredFailedOrders() public view {
        uint256[2] memory byAgent;
        uint256[3] memory byService;
        for (uint256 i; i < _handler.orderCount(); ++i) {
            bytes32 orderKey = _handler.orderAt(i);
            (uint64 recoveredAt, bytes32 evidenceHash, bytes32 attestationUid) = reputation.getRecovery(orderKey);
            if (recoveredAt == 0) {
                assertEq(evidenceHash, bytes32(0));
                assertEq(attestationUid, bytes32(0));
                continue;
            }
            ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(orderKey);
            assertTrue(record.reputationEligible && record.outcomeRecorded);
            assertEq(uint8(record.outcome), uint8(ReputationStorageBase.TransactionOutcome.Failed));
            assertLe(recoveredAt, block.timestamp);
            assertTrue(evidenceHash != bytes32(0) && attestationUid != bytes32(0));
            byAgent[record.providerAgentId == PROVIDER_AGENT_ID ? 0 : 1]++;
            byService[record.serviceId == serviceId ? 0 : record.serviceId == secondServiceId ? 1 : 2]++;
        }
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), byAgent[0]);
        assertEq(reputation.recoveredCount(SECOND_AGENT_ID), byAgent[1]);
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), _handler.expectedRecoveredCount(PROVIDER_AGENT_ID));
        assertEq(reputation.recoveredCount(SECOND_AGENT_ID), _handler.expectedRecoveredCount(SECOND_AGENT_ID));
        bytes32[3] memory serviceIds = [serviceId, secondServiceId, thirdServiceId];
        for (uint256 i; i < serviceIds.length; ++i) {
            assertEq(reputation.recoveredByService(serviceIds[i]), byService[i]);
            assertEq(reputation.recoveredByService(serviceIds[i]), _handler.expectedRecoveredByService(serviceIds[i]));
        }
    }
}
