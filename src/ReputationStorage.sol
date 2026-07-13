// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICanonicalIdentity} from "./interfaces/ICanonicalIdentity.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IEAS, Attestation} from "./interfaces/IEAS.sol";
import {ISchemaResolver} from "./interfaces/ISchemaResolver.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";

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
/// auth (the attester must control the payment's provider/buyer agent on the
/// canonical ERC-8004 registry), and updates counters. The resolver still exposes `recordRefund` so the
/// PaymentRouter's best-effort refund mirror keeps working unchanged.
///
/// Two schemas are registered against this resolver:
///   * `outcome`:        (uint256 paymentId, uint8 outcome)
///                       — provider-attested, one-shot per paymentId. The
///                         on-chain fulfillment time is derived in the
///                         resolver as
///                         `block.timestamp - PaymentRouter.PaymentRecord.paidAt`,
///                         not taken from the attester — the provider's
///                         self-reported number is gameable.
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
contract ReputationStorage is Admin2StepUpgradeable, ISchemaResolver {
    enum TransactionOutcome {
        Completed,
        Failed,
        Canceled
    }

    /// @notice Binary confirmation. `Pending` is no longer *attestable* — the
    ///         resolver rejects attest payloads carrying it ("binary
    ///         confirmation only") — but the variant is retained at ordinal 0
    ///         to serve as the storage sentinel for "no confirmation yet".
    ///         Downstream callers read `Pending` from `getRecord(...)` when an
    ///         outcome was attested before any buyer confirmation, and from
    ///         `confirmationByUid[...]` for any UID this resolver never
    ///         credited.
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

    mapping(uint256 => ReputationRecord) internal _records;
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

    ICanonicalIdentity public identity;
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
    ///         (uint256 paymentId, uint8 outcome).
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
        __Admin2Step_init(_admin);
        identity = ICanonicalIdentity(_identity);
        paymentRouter = IPaymentRouter(_paymentRouter);
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
        (uint256 paymentId, uint8 outcomeRaw) = abi.decode(a.data, (uint256, uint8));
        require(outcomeRaw <= uint8(TransactionOutcome.Canceled), "bad outcome");
        TransactionOutcome outcome = TransactionOutcome(outcomeRaw);

        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);

        // The attester must currently control the payment's provider agent
        // on the canonical registry. The agentId comes from the immutable
        // PaymentRecord, so this is a direct verification — no reverse
        // index required.
        require(_controlsAgent(payment.providerAgentId, a.attester), "not provider for this payment");

        ReputationRecord storage record = _records[paymentId];
        require(!record.outcomeRecorded, "outcome already recorded");

        // Lazy record creation — may have been partially created by the buyer
        // (a confirmation can land before the provider attests the outcome).
        // Either path stamps the canonical serviceId from the PaymentRecord.
        if (record.paymentId == 0) {
            record.paymentId = paymentId;
            record.providerAgentId = payment.providerAgentId;
            record.buyerAgentId = payment.buyerAgentId;
            record.serviceId = payment.serviceId;
            recordIds.push(paymentId);
        }

        // Derive fulfillmentTime from on-chain timestamps. `paidAt` is set
        // unconditionally by PaymentRouter.settle() and `block.timestamp` is
        // the moment of outcome attestation, so the difference is the true
        // wall-clock turnaround — and unlike a self-reported value, it cannot
        // be gamed by the attesting provider.
        uint256 fulfillmentTime = block.timestamp - payment.paidAt;

        record.outcome = outcome;
        record.fulfillmentTime = fulfillmentTime;
        record.outcomeTimestamp = block.timestamp;
        record.outcomeRecorded = true;

        if (outcome == TransactionOutcome.Completed) {
            completedCount[payment.providerAgentId]++;
            completedByService[record.serviceId]++;
        } else if (outcome == TransactionOutcome.Failed) {
            failedCount[payment.providerAgentId]++;
            failedByService[record.serviceId]++;
        } else {
            canceledCount[payment.providerAgentId]++;
            canceledByService[record.serviceId]++;
        }

        buyerTransactionCount[payment.buyerAgentId]++;

        emit OutcomeRecorded(
            paymentId, payment.providerAgentId, payment.buyerAgentId, record.serviceId, outcome, fulfillmentTime, a.uid
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

        // Same direct verification as the outcome path, against the
        // payment's buyer agent.
        require(_controlsAgent(payment.buyerAgentId, a.attester), "not buyer for this payment");

        ReputationRecord storage record = _records[paymentId];
        if (record.paymentId == 0) {
            record.paymentId = paymentId;
            record.providerAgentId = payment.providerAgentId;
            record.buyerAgentId = payment.buyerAgentId;
            record.serviceId = payment.serviceId;
            recordIds.push(paymentId);
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

    // ── Attester auth ───────────────────────────────────────────────────

    /// @dev "Controls" = the agent's current verified agentWallet on the
    ///      canonical ERC-8004 registry, or its ERC-721 owner. The canonical
    ///      registry never auto-sets agentWallet, so for agents minted via
    ///      AgentIndex the owner branch is the common case. `who` is an EAS
    ///      attester and never zero; an unset agentWallet (zero) can
    ///      therefore never match it.
    function _controlsAgent(uint256 agentId, address who) internal view returns (bool) {
        if (identity.getAgentWallet(agentId) == who) return true;
        return identity.ownerOf(agentId) == who;
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

    function setPaymentRouter(address newRouter) external onlyAdmin {
        require(newRouter != address(0), "zero router");
        // All reputation state is keyed by the router's paymentId. Re-pointing
        // at a different router (whose IDs restart at 1) would collide new
        // payments with existing records and corrupt counters. Once any record
        // exists, the only safe migration is a full-stack redeploy — this
        // guard makes that invariant self-enforcing.
        require(recordIds.length == 0, "records exist");
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

    // @dev receive() for EAS `isPayable` legacy — we return false from
    //      isPayable() so EAS won't forward value, but leaving this absent
    //      means any accidental value-carrying attest() reverts on the
    //      resolver's `payable` call. That's fine.

    uint256[50] private __gap;
}
