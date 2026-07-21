// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IEAS} from "../interfaces/IEAS.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Shared reputation types, counters, and resolver configuration.
abstract contract ReputationStorageBase is Admin2StepUpgradeable {
    enum TransactionOutcome {
        Completed,
        Failed,
        Canceled
    }

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
        uint256 outcomeAttestationDelay;
        uint256 outcomeTimestamp;
        uint256 confirmationTimestamp;
        bool outcomeRecorded;
        bytes32 currentConfirmationUid;
        bool reputationEligible;
    }

    mapping(uint256 => ReputationRecord) internal _records;
    uint256[] public recordIds;

    mapping(uint256 => uint256) public completedCount;
    mapping(uint256 => uint256) public failedCount;
    mapping(uint256 => uint256) public canceledCount;
    mapping(uint256 => uint256) public confirmedCount;
    mapping(uint256 => uint256) public notConfirmedCount;
    mapping(uint256 => uint256) public providerTransactionCount;

    mapping(uint256 => uint256) public buyerConfirmedCount;
    mapping(uint256 => uint256) public buyerNotConfirmedCount;
    mapping(uint256 => uint256) public buyerTransactionCount;

    IPaymentRouter public paymentRouter;
    mapping(uint256 => uint256) public refundedAmount;

    IEAS public eas;
    bytes32 public outcomeSchema;
    bytes32 public confirmationSchema;
    bool internal _configured;
    mapping(bytes32 => BuyerConfirmation) public confirmationByUid;
    mapping(bytes32 => uint256) public paymentIdByUid;

    mapping(bytes32 => uint256) public completedByService;
    mapping(bytes32 => uint256) public failedByService;
    mapping(bytes32 => uint256) public canceledByService;
    mapping(bytes32 => uint256) public confirmedByService;
    mapping(bytes32 => uint256) public notConfirmedByService;
    mapping(bytes32 => uint256) public serviceTransactionCount;
    mapping(bytes32 => uint256) public refundedAmountByService;

    event OutcomeRecorded(
        uint256 indexed paymentId,
        uint256 indexed providerAgentId,
        uint256 indexed buyerAgentId,
        bytes32 serviceId,
        TransactionOutcome outcome,
        uint256 outcomeAttestationDelay,
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
    event PaymentRecorded(
        uint256 indexed paymentId,
        uint256 indexed providerAgentId,
        uint256 indexed buyerAgentId,
        bytes32 serviceId,
        bool reputationEligible
    );
    event EASUpdated(address indexed oldEAS, address indexed newEAS);
    event OutcomeSchemaUpdated(bytes32 indexed oldSchema, bytes32 indexed newSchema);
    event ConfirmationSchemaUpdated(bytes32 indexed oldSchema, bytes32 indexed newSchema);
    event ConfigurationFinalized(
        address indexed paymentRouter, address indexed eas, bytes32 indexed outcomeSchema, bytes32 confirmationSchema
    );

    modifier onlyPaymentRouter() {
        require(msg.sender == address(paymentRouter), "not payment router");
        _;
    }

    modifier onlyEAS() {
        require(msg.sender == address(eas), "not EAS");
        _;
    }

    function _initializeReputation(address paymentRouter_, address sanctionsOracle_, address admin_)
        internal
        onlyInitializing
    {
        require(paymentRouter_ != address(0), "zero router");
        __Admin2Step_init(admin_, sanctionsOracle_);
        paymentRouter = IPaymentRouter(paymentRouter_);
    }

    uint256[50] private _gap;
}
