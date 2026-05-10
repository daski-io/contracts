// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IEAS, Attestation} from "./interfaces/IEAS.sol";
import {ISchemaResolver} from "./interfaces/ISchemaResolver.sol";

/// @notice Daski-specific bilateral reputation aggregator. Rather than store
///         per-transaction signals in this contract directly (as an earlier
///         version did), this contract now lives as an **EAS schema resolver**.
///         EAS is the source of truth for every individual outcome /
///         confirmation attestation, and this contract maintains the
///         aggregate counters (per-provider, per-service, per-buyer) the rest
///         of the Daski stack reads for discovery ranking.
///
/// Per the Daski whitepaper §Reputation: "Per-transaction signals are stored
/// as attestations via the Ethereum Attestation Service (EAS)." EAS calls
/// `onAttest`/`onRevoke` on this resolver for every attestation against the
/// Daski schemas; the resolver decodes the payload, enforces Daski-specific
/// auth (provider agent vs. buyer agent from the IdentityRegistry), and
/// updates counters. The resolver still exposes `recordRefund` so the
/// PaymentRouter's best-effort refund mirror keeps working unchanged.
///
/// Two schemas are registered against this resolver:
///   * `outcome`:        (uint256 paymentId, uint8 outcome, uint256 fulfillmentTime)
///                       — provider-attested, one-shot per paymentId. The
///                         `fulfillmentTime` field is preserved in the schema
///                         for back-compat with already-registered EAS
///                         schemas, but the resolver IGNORES it and derives
///                         the real fulfillment time as
///                         `block.timestamp - PaymentRouter.PaymentRecord.paidAt`.
///                         The attested value is only used as a fallback for
///                         pre-upgrade payments where `paidAt` was never
///                         written (reads as 0 from the legacy mapping slot).
///   * `confirmation`:   (uint256 paymentId, uint8 confirmation)
///                       — buyer-attested, revisions allowed via EAS refUID;
///                         resolver rebalances counters on each revision.
///
/// `serviceId` is NOT a schema field. It is derived from
/// `PaymentRouter.getPayment(paymentId).serviceId` so the off-chain attester
/// cannot lie about which service a feedback applies to.
///
/// Reads (`getRecord`, `getProviderStats`, `getServiceStats`, `getBuyerStats`,
/// `getRefundedAmount`) preserve the exact shape the pre-EAS version exposed
/// so the off-chain gateway / provider read paths remain a drop-in.
contract ReputationStorage is Initializable, UUPSUpgradeable, ISchemaResolver {
    enum TransactionOutcome {
        Completed,
        Failed,
        Canceled
    }

    /// @notice Binary confirmation (Pending was removed in the EAS migration —
    ///         absence of an attestation IS pending). Kept at the same ordinal
    ///         values as before so downstream callers don't have to re-map.
    enum BuyerConfirmation {
        Pending,
        Confirmed,
        NotConfirmed
    }

    struct ReputationRecord {
        uint256 paymentId;
        uint256 providerAgentId;
        uint256 buyerAgentId;
        bytes32 serviceId;
        TransactionOutcome outcome;
        BuyerConfirmation confirmation;
        uint256 fulfillmentTime;
        uint256 outcomeTimestamp;
        uint256 confirmationTimestamp;
        bool outcomeRecorded;
    }

    // ── Storage ─────────────────────────────────────────────────────────

    mapping(uint256 => ReputationRecord) public _records;
    uint256[] public recordIds;

    // Per-provider aggregate counters
    mapping(uint256 => uint256) public completedCount;
    mapping(uint256 => uint256) public failedCount;
    mapping(uint256 => uint256) public canceledCount;
    mapping(uint256 => uint256) public confirmedCount;
    mapping(uint256 => uint256) public notConfirmedCount;

    // Per-buyer aggregate counters
    mapping(uint256 => uint256) public buyerConfirmedCount;
    mapping(uint256 => uint256) public buyerNotConfirmedCount;
    mapping(uint256 => uint256) public buyerTransactionCount;

    address public admin;
    address public pendingAdmin;
    IdentityRegistry public identity;
    IPaymentRouter public paymentRouter;

    /// @notice Cumulative refund amount per paymentId, recorded by the
    ///         PaymentRouter when a provider issues a refund.
    mapping(uint256 => uint256) public refundedAmount;

    // ── EAS wiring ──────────────────────────────────────────────────────

    /// @notice The EAS contract authorized to invoke `attest` / `revoke`
    ///         on this resolver. On Base (and Base Sepolia) this is the
    ///         canonical deploy at 0x4200000000000000000000000000000000000021.
    IEAS public eas;

    /// @notice EAS schema UID for the outcome schema
    ///         (uint256 paymentId, uint8 outcome, uint256 fulfillmentTime).
    ///         The third field is decoded but no longer trusted — see the
    ///         contract-level NatSpec and `_onOutcomeAttest`.
    bytes32 public outcomeSchema;

    /// @notice EAS schema UID for the buyer confirmation schema
    ///         (uint256 paymentId, uint8 confirmation).
    bytes32 public confirmationSchema;

    /// @notice Maps a confirmation attestation UID to the confirmation value
    ///         the resolver credited to the counters. Used when a later
    ///         revision references this UID via `refUID` so we can decrement
    ///         the old counter before incrementing the new one.
    mapping(bytes32 => BuyerConfirmation) public confirmationByUid;

    /// @notice Maps a confirmation attestation UID to the paymentId it was
    ///         credited against. Required so a revision (refUID-linked
    ///         attestation) can be bound to the same paymentId — without
    ///         this, a malicious buyer could reference an unrelated
    ///         confirmation UID and corrupt another provider's counters
    ///         while orphaning the legitimate UID.
    mapping(bytes32 => uint256) public paymentIdByUid;

    // ── Per-service counters (added by the service-identity refactor) ───

    mapping(bytes32 => uint256) public completedByService;
    mapping(bytes32 => uint256) public failedByService;
    mapping(bytes32 => uint256) public canceledByService;
    mapping(bytes32 => uint256) public confirmedByService;
    mapping(bytes32 => uint256) public notConfirmedByService;
    /// @notice Cumulative refunded USDC across all payments for this service.
    mapping(bytes32 => uint256) public refundedAmountByService;

    // ── Events ──────────────────────────────────────────────────────────

    event OutcomeRecorded(
        uint256 indexed paymentId,
        uint256 indexed providerAgentId,
        uint256 indexed buyerAgentId,
        bytes32 serviceId,
        TransactionOutcome outcome,
        uint256 fulfillmentTime,
        bytes32 attestationUid
    );

    event BuyerConfirmationSubmitted(
        uint256 indexed paymentId,
        uint256 indexed providerAgentId,
        uint256 indexed buyerAgentId,
        bytes32 serviceId,
        BuyerConfirmation confirmation,
        bytes32 attestationUid,
        bytes32 refUid
    );

    event ReputationRefunded(
        uint256 indexed paymentId, bytes32 indexed serviceId, uint256 amountToBuyer, uint256 cumulativeRefunded
    );

    event PaymentRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event EASUpdated(address indexed oldEAS, address indexed newEAS);
    event OutcomeSchemaUpdated(bytes32 indexed oldSchema, bytes32 indexed newSchema);
    event ConfirmationSchemaUpdated(bytes32 indexed oldSchema, bytes32 indexed newSchema);

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyPaymentRouter() {
        require(msg.sender == address(paymentRouter), "not payment router");
        _;
    }

    modifier onlyEAS() {
        require(msg.sender == address(eas), "not EAS");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identity, address _paymentRouter, address _admin) external initializer {
        require(_identity != address(0), "zero identity");
        require(_paymentRouter != address(0), "zero router");
        require(_admin != address(0), "zero admin");
        identity = IdentityRegistry(_identity);
        paymentRouter = IPaymentRouter(_paymentRouter);
        admin = _admin;
    }

    // ── ISchemaResolver ─────────────────────────────────────────────────

    /// @inheritdoc ISchemaResolver
    function isPayable() external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc ISchemaResolver
    function attest(Attestation calldata attestation) external payable override onlyEAS returns (bool) {
        _handleAttest(attestation);
        return true;
    }

    /// @inheritdoc ISchemaResolver
    function multiAttest(
        Attestation[] calldata attestations,
        uint256[] calldata /* values */
    )
        external
        payable
        override
        onlyEAS
        returns (bool)
    {
        for (uint256 i = 0; i < attestations.length; i++) {
            _handleAttest(attestations[i]);
        }
        return true;
    }

    /// @inheritdoc ISchemaResolver
    function revoke(Attestation calldata attestation) external payable override onlyEAS returns (bool) {
        _handleRevoke(attestation);
        return true;
    }

    /// @inheritdoc ISchemaResolver
    function multiRevoke(
        Attestation[] calldata attestations,
        uint256[] calldata /* values */
    )
        external
        payable
        override
        onlyEAS
        returns (bool)
    {
        for (uint256 i = 0; i < attestations.length; i++) {
            _handleRevoke(attestations[i]);
        }
        return true;
    }

    // ── Internal routing ────────────────────────────────────────────────

    function _handleAttest(Attestation calldata a) internal {
        if (a.schema == outcomeSchema) {
            _onOutcomeAttest(a);
        } else if (a.schema == confirmationSchema) {
            _onConfirmationAttest(a);
        } else {
            revert("unknown schema");
        }
    }

    function _handleRevoke(Attestation calldata a) internal {
        if (a.schema == confirmationSchema) {
            _onConfirmationRevoke(a);
        } else if (a.schema == outcomeSchema) {
            // Outcomes are one-shot and historically final. Reject revocation
            // to preserve monotonic counters and deter accidental state loss.
            revert("outcomes are not revocable");
        } else {
            revert("unknown schema");
        }
    }

    // ── Outcome logic ───────────────────────────────────────────────────

    function _onOutcomeAttest(Attestation calldata a) internal {
        (uint256 paymentId, uint8 outcomeRaw, uint256 attestedFulfillmentTime) =
            abi.decode(a.data, (uint256, uint8, uint256));
        require(outcomeRaw <= uint8(TransactionOutcome.Canceled), "bad outcome");
        TransactionOutcome outcome = TransactionOutcome(outcomeRaw);

        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);

        uint256 attesterAgentId = identity.agentOfWallet(a.attester);
        require(attesterAgentId != 0, "no identity");
        require(attesterAgentId == payment.providerAgentId, "not provider for this payment");

        ReputationRecord storage record = _records[paymentId];
        require(!record.outcomeRecorded, "outcome already recorded");

        // Lazy record creation — may have been partially created by buyer.
        if (record.paymentId == 0) {
            record.paymentId = paymentId;
            record.providerAgentId = payment.providerAgentId;
            record.buyerAgentId = payment.buyerAgentId;
            record.serviceId = payment.serviceId;
            recordIds.push(paymentId);
        } else if (record.serviceId == bytes32(0)) {
            // Confirmation arrived before outcome and was created on the
            // pre-refactor router (no serviceId on record). Backfill from
            // the canonical PaymentRouter record.
            record.serviceId = payment.serviceId;
        }

        // Derive fulfillmentTime from on-chain timestamps rather than the
        // attestation. The provider's claim is gameable (they can plug any
        // number into the schema's third field); `paidAt` was set by
        // PaymentRouter at settle and `block.timestamp` is the moment of
        // outcome attestation, so the difference is the true wall-clock
        // turnaround.
        //
        // Fallback: PaymentRouter entries written before the paidAt upgrade
        // read as 0 (storage slot never written). For those, fall back to
        // the attested value so legacy payments don't surface a giant bogus
        // `block.timestamp` as their fulfillment time. New payments always
        // have paidAt > 0 because settle() sets it unconditionally.
        uint256 fulfillmentTime = payment.paidAt > 0 ? block.timestamp - payment.paidAt : attestedFulfillmentTime;

        record.outcome = outcome;
        record.fulfillmentTime = fulfillmentTime;
        record.outcomeTimestamp = block.timestamp;
        record.outcomeRecorded = true;

        if (outcome == TransactionOutcome.Completed) {
            completedCount[payment.providerAgentId]++;
            completedByService[payment.serviceId]++;
        } else if (outcome == TransactionOutcome.Failed) {
            failedCount[payment.providerAgentId]++;
            failedByService[payment.serviceId]++;
        } else {
            canceledCount[payment.providerAgentId]++;
            canceledByService[payment.serviceId]++;
        }

        buyerTransactionCount[payment.buyerAgentId]++;

        emit OutcomeRecorded(
            paymentId, payment.providerAgentId, payment.buyerAgentId, payment.serviceId, outcome, fulfillmentTime, a.uid
        );
    }

    // ── Confirmation logic (with revision rebalance) ────────────────────

    function _onConfirmationAttest(Attestation calldata a) internal {
        (uint256 paymentId, uint8 confirmationRaw) = abi.decode(a.data, (uint256, uint8));
        require(
            confirmationRaw == uint8(BuyerConfirmation.Confirmed)
                || confirmationRaw == uint8(BuyerConfirmation.NotConfirmed),
            "binary confirmation only"
        );
        BuyerConfirmation confirmation = BuyerConfirmation(confirmationRaw);

        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);

        uint256 attesterAgentId = identity.agentOfWallet(a.attester);
        require(attesterAgentId != 0, "no identity");
        require(attesterAgentId == payment.buyerAgentId, "not buyer for this payment");

        ReputationRecord storage record = _records[paymentId];
        if (record.paymentId == 0) {
            record.paymentId = paymentId;
            record.providerAgentId = payment.providerAgentId;
            record.buyerAgentId = payment.buyerAgentId;
            record.serviceId = payment.serviceId;
            recordIds.push(paymentId);
        } else if (record.serviceId == bytes32(0)) {
            record.serviceId = payment.serviceId;
        }

        // Revision path: if `refUID` is set, it MUST point at a confirmation
        // we previously credited *for the same paymentId*. Without the
        // paymentId binding, a malicious buyer could reference an unrelated
        // confirmation UID — the resolver would then decrement the wrong
        // provider/buyer counters and orphan the referenced UID, blocking
        // legitimate revisions and revocations.
        if (a.refUID != bytes32(0)) {
            require(a.refUID != a.uid, "self refUID");
            BuyerConfirmation old = confirmationByUid[a.refUID];
            require(old != BuyerConfirmation.Pending, "refUID is not a tracked confirmation");
            require(paymentIdByUid[a.refUID] == paymentId, "refUID belongs to different payment");
            if (old == BuyerConfirmation.Confirmed) {
                confirmedCount[payment.providerAgentId]--;
                confirmedByService[record.serviceId]--;
                buyerConfirmedCount[payment.buyerAgentId]--;
            } else {
                notConfirmedCount[payment.providerAgentId]--;
                notConfirmedByService[record.serviceId]--;
                buyerNotConfirmedCount[payment.buyerAgentId]--;
            }
            // Clear the mapping so the old UID can't be used as a refUID
            // again (prevents a double-decrement attack via a chain that
            // branches off an already-superseded confirmation).
            delete confirmationByUid[a.refUID];
            delete paymentIdByUid[a.refUID];
        } else {
            // First-time confirmation — require there is no confirmation yet.
            require(record.confirmation == BuyerConfirmation.Pending, "must ref prior confirmation");
        }

        record.confirmation = confirmation;
        record.confirmationTimestamp = block.timestamp;

        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[payment.providerAgentId]++;
            confirmedByService[record.serviceId]++;
            buyerConfirmedCount[payment.buyerAgentId]++;
        } else {
            notConfirmedCount[payment.providerAgentId]++;
            notConfirmedByService[record.serviceId]++;
            buyerNotConfirmedCount[payment.buyerAgentId]++;
        }

        confirmationByUid[a.uid] = confirmation;
        paymentIdByUid[a.uid] = paymentId;

        emit BuyerConfirmationSubmitted(
            paymentId, payment.providerAgentId, payment.buyerAgentId, record.serviceId, confirmation, a.uid, a.refUID
        );
    }

    function _onConfirmationRevoke(Attestation calldata a) internal {
        // Revocation of a confirmation without a superseding attestation: if
        // we still credit this UID, decrement. If the UID was already
        // superseded by a revision, nothing to do.
        BuyerConfirmation old = confirmationByUid[a.uid];
        if (old == BuyerConfirmation.Pending) return;

        // Use the paymentId we recorded for this UID rather than re-decoding
        // a.data — the recorded mapping is authoritative for what we
        // credited, and using it keeps the revoke handler symmetric with the
        // attest handler.
        uint256 paymentId = paymentIdByUid[a.uid];
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        ReputationRecord storage record = _records[paymentId];

        if (old == BuyerConfirmation.Confirmed) {
            confirmedCount[payment.providerAgentId]--;
            confirmedByService[record.serviceId]--;
            buyerConfirmedCount[payment.buyerAgentId]--;
        } else {
            notConfirmedCount[payment.providerAgentId]--;
            notConfirmedByService[record.serviceId]--;
            buyerNotConfirmedCount[payment.buyerAgentId]--;
        }
        delete confirmationByUid[a.uid];
        delete paymentIdByUid[a.uid];

        // If the revoked attestation was the *current* confirmation on the
        // record, roll back the record too so `getRecord` reflects reality.
        if (record.confirmation == old) {
            record.confirmation = BuyerConfirmation.Pending;
            record.confirmationTimestamp = 0;
        }
    }

    // ── Refund mirror (per-service dimension added) ─────────────────────

    /// @notice Called by the PaymentRouter when a provider refunds (partial
    ///         or full). Aggregates into `refundedAmount[paymentId]` and
    ///         `refundedAmountByService[serviceId]`.
    /// @dev    The serviceId is read from the local record if present, or
    ///         lazy-fetched from the router for refund-before-outcome paths.
    function recordRefund(uint256 paymentId, uint256 amountToBuyer) external onlyPaymentRouter {
        ReputationRecord storage record = _records[paymentId];
        bytes32 svcId = record.serviceId;
        if (svcId == bytes32(0)) {
            svcId = paymentRouter.getPayment(paymentId).serviceId;
        }

        uint256 cumulative = refundedAmount[paymentId] + amountToBuyer;
        refundedAmount[paymentId] = cumulative;
        refundedAmountByService[svcId] += amountToBuyer;
        emit ReputationRefunded(paymentId, svcId, amountToBuyer, cumulative);
    }

    // ── Views ───────────────────────────────────────────────────────────

    function getRecord(uint256 paymentId) external view returns (ReputationRecord memory) {
        return _records[paymentId];
    }

    /// @notice Number of paymentIds that have a reputation record. Pair with
    ///         the auto-generated `recordIds(uint256)` getter to enumerate.
    function getRecordCount() external view returns (uint256) {
        return recordIds.length;
    }

    function getRefundedAmount(uint256 paymentId) external view returns (uint256) {
        return refundedAmount[paymentId];
    }

    function getProviderStats(uint256 providerAgentId)
        external
        view
        returns (uint256 completed, uint256 failed, uint256 canceled, uint256 confirmed, uint256 notConfirmed_)
    {
        completed = completedCount[providerAgentId];
        failed = failedCount[providerAgentId];
        canceled = canceledCount[providerAgentId];
        confirmed = confirmedCount[providerAgentId];
        notConfirmed_ = notConfirmedCount[providerAgentId];
    }

    /// @notice Per-service reputation tuple. Provider-level stats blend
    ///         across all services; this view returns the service-scoped
    ///         numbers needed for category-level discovery ranking.
    function getServiceStats(bytes32 serviceId)
        external
        view
        returns (
            uint256 completed,
            uint256 failed,
            uint256 canceled,
            uint256 confirmed,
            uint256 notConfirmed_,
            uint256 totalRefunded
        )
    {
        completed = completedByService[serviceId];
        failed = failedByService[serviceId];
        canceled = canceledByService[serviceId];
        confirmed = confirmedByService[serviceId];
        notConfirmed_ = notConfirmedByService[serviceId];
        totalRefunded = refundedAmountByService[serviceId];
    }

    function getBuyerStats(uint256 buyerAgentId)
        external
        view
        returns (uint256 transactions, uint256 confirmed, uint256 notConfirmed_)
    {
        transactions = buyerTransactionCount[buyerAgentId];
        confirmed = buyerConfirmedCount[buyerAgentId];
        notConfirmed_ = buyerNotConfirmedCount[buyerAgentId];
    }

    // ── Admin ───────────────────────────────────────────────────────────

    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    function setPaymentRouter(address newRouter) external onlyAdmin {
        require(newRouter != address(0), "zero router");
        address oldRouter = address(paymentRouter);
        paymentRouter = IPaymentRouter(newRouter);
        emit PaymentRouterUpdated(oldRouter, newRouter);
    }

    function setEAS(address newEAS) external onlyAdmin {
        require(newEAS != address(0), "zero eas");
        address oldEAS = address(eas);
        eas = IEAS(newEAS);
        emit EASUpdated(oldEAS, newEAS);
    }

    function setOutcomeSchema(bytes32 newSchema) external onlyAdmin {
        require(newSchema != bytes32(0), "zero schema");
        bytes32 oldSchema = outcomeSchema;
        outcomeSchema = newSchema;
        emit OutcomeSchemaUpdated(oldSchema, newSchema);
    }

    function setConfirmationSchema(bytes32 newSchema) external onlyAdmin {
        require(newSchema != bytes32(0), "zero schema");
        bytes32 oldSchema = confirmationSchema;
        confirmationSchema = newSchema;
        emit ConfirmationSchemaUpdated(oldSchema, newSchema);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    // @dev receive() for EAS `isPayable` legacy — we return false from
    //      isPayable() so EAS won't forward value, but leaving this absent
    //      means any accidental value-carrying attest() reverts on the
    //      resolver's `payable` call. That's fine.
}
