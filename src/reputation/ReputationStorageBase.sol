// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IEAS} from "../interfaces/IEAS.sol";
import {IProviderRegistry} from "../interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "../interfaces/IServiceRegistry.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Shared standard-order reputation types, counters, and configuration.
abstract contract ReputationStorageBase is Admin2StepUpgradeable, EIP712Upgradeable {
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

    struct StandardReputationOrderV1 {
        bytes32 orderKey;
        bytes32 authorizationKey;
        uint256 providerAgentId;
        bytes32 serviceId;
        address payer;
        address providerOwner;
        address providerAgentWallet;
        address providerPayee;
        address identityRegistry;
        address providerRegistry;
        address serviceRegistry;
        uint256 blockNumber;
        bytes32 blockHash;
        address canonicalToken;
        uint256 grossAmount;
        uint64 paidAt;
        bytes32 providerIdentitySnapshotHash;
        bytes32 listingManifestHash;
        bytes32 releaseEvidenceHash;
        bool reputationEligible;
        uint64 validBefore;
    }

    struct StandardReputationRefundV1 {
        bytes32 orderKey;
        bytes32 authorizationKey;
        uint256 cumulativeRefundedAmount;
        bytes32 refundEvidenceHash;
        uint64 validBefore;
    }

    struct ReputationRecord {
        bytes32 orderKey;
        bytes32 authorizationKey;
        uint256 providerAgentId;
        bytes32 serviceId;
        address payer;
        address providerOwner;
        address providerAgentWallet;
        address providerPayee;
        address canonicalToken;
        uint256 grossAmount;
        uint64 paidAt;
        bytes32 providerIdentitySnapshotHash;
        bytes32 listingManifestHash;
        bytes32 releaseEvidenceHash;
        TransactionOutcome outcome;
        BuyerConfirmation confirmation;
        uint64 outcomeAttestationDelay;
        uint64 outcomeTimestamp;
        uint64 confirmationTimestamp;
        uint8 confirmationTransitions;
        bool outcomeRecorded;
        bool reputationEligible;
        bytes32 currentConfirmationUid;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "StandardReputationOrderV1(bytes32 orderKey,bytes32 authorizationKey,uint256 providerAgentId,bytes32 serviceId,address payer,address providerOwner,address providerAgentWallet,address providerPayee,address identityRegistry,address providerRegistry,address serviceRegistry,uint256 blockNumber,bytes32 blockHash,address canonicalToken,uint256 grossAmount,uint64 paidAt,bytes32 providerIdentitySnapshotHash,bytes32 listingManifestHash,bytes32 releaseEvidenceHash,bool reputationEligible,uint64 validBefore)"
    );
    bytes32 public constant REFUND_TYPEHASH = keccak256(
        "StandardReputationRefundV1(bytes32 orderKey,bytes32 authorizationKey,uint256 cumulativeRefundedAmount,bytes32 refundEvidenceHash,uint64 validBefore)"
    );
    bytes32 public constant PROVIDER_IDENTITY_SNAPSHOT_V1_TYPEHASH = keccak256(
        "ProviderIdentitySnapshotV1(uint256 chainId,uint256 providerAgentId,bytes32 serviceId,address identityRegistry,address providerRegistry,address serviceRegistry,address providerOwner,address providerAgentWallet,address providerPayee,uint256 blockNumber,bytes32 blockHash)"
    );

    mapping(bytes32 => ReputationRecord) internal _records;
    bytes32[] public recordKeys;
    mapping(bytes32 => bool) public authorizationKeyUsed;
    mapping(bytes32 => uint256) public refundedAmount;
    mapping(bytes32 => BuyerConfirmation) public confirmationByUid;
    mapping(bytes32 => bytes32) public orderKeyByConfirmationUid;

    mapping(uint256 => uint256) public completedCount;
    mapping(uint256 => uint256) public failedCount;
    mapping(uint256 => uint256) public canceledCount;
    mapping(uint256 => uint256) public confirmedCount;
    mapping(uint256 => uint256) public notConfirmedCount;
    mapping(uint256 => uint256) public providerTransactionCount;
    mapping(uint256 => uint256) public totalPaidByProvider;
    mapping(uint256 => uint256) public refundedAmountByProvider;
    mapping(uint256 => uint256) public outcomeDelayTotalByProvider;

    mapping(bytes32 => uint256) public completedByService;
    mapping(bytes32 => uint256) public failedByService;
    mapping(bytes32 => uint256) public canceledByService;
    mapping(bytes32 => uint256) public confirmedByService;
    mapping(bytes32 => uint256) public notConfirmedByService;
    mapping(bytes32 => uint256) public serviceTransactionCount;
    mapping(bytes32 => uint256) public totalPaidByService;
    mapping(bytes32 => uint256) public refundedAmountByService;

    mapping(address => uint256) public payerTransactionCount;
    mapping(address => uint256) public payerConfirmedCount;
    mapping(address => uint256) public payerNotConfirmedCount;
    mapping(address => uint256) public totalPaidByPayer;
    mapping(address => uint256) public refundedAmountByPayer;

    mapping(uint256 => uint256) public confirmedWeightByProvider;
    mapping(uint256 => uint256) public notConfirmedWeightByProvider;
    mapping(bytes32 => uint256) public confirmedWeightByService;
    mapping(bytes32 => uint256) public notConfirmedWeightByService;

    IEAS public eas;
    IProviderRegistry public providerRegistry;
    IServiceRegistry public serviceRegistry;
    address public identityRegistry;
    address public orderSigner;
    bytes32 public outcomeSchema;
    bytes32 public confirmationSchema;
    bool internal _configured;

    event StandardOrderRegistered(
        bytes32 indexed orderKey,
        bytes32 indexed authorizationKey,
        uint256 indexed providerAgentId,
        bytes32 serviceId,
        address payer,
        uint256 grossAmount,
        bool reputationEligible
    );
    event OutcomeRecorded(
        bytes32 indexed orderKey,
        uint256 indexed providerAgentId,
        address indexed payer,
        bytes32 serviceId,
        TransactionOutcome outcome,
        uint256 attestationDelay,
        bytes32 attestationUid
    );
    event BuyerConfirmationSubmitted(
        bytes32 indexed orderKey,
        uint256 indexed providerAgentId,
        address indexed payer,
        bytes32 serviceId,
        BuyerConfirmation confirmation,
        bytes32 attestationUid,
        bytes32 refUid,
        uint8 transitionCount
    );
    event BuyerConfirmationRevoked(
        bytes32 indexed orderKey, bytes32 indexed attestationUid, address indexed payer, uint8 transitionCount
    );
    event ReputationRefunded(
        bytes32 indexed orderKey,
        bytes32 indexed serviceId,
        uint256 delta,
        uint256 cumulativeRefunded,
        bytes32 refundEvidenceHash
    );
    event EASUpdated(address indexed oldEAS, address indexed newEAS);
    event OrderSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event OutcomeSchemaUpdated(bytes32 indexed oldSchema, bytes32 indexed newSchema);
    event ConfirmationSchemaUpdated(bytes32 indexed oldSchema, bytes32 indexed newSchema);
    event ConfigurationFinalized(
        address indexed eas,
        address indexed orderSigner,
        address indexed identityRegistry,
        address providerRegistry,
        address serviceRegistry,
        bytes32 outcomeSchema,
        bytes32 confirmationSchema
    );

    modifier onlyEAS() {
        require(msg.sender == address(eas), "not EAS");
        _;
    }

    function _initializeReputation(
        address orderSigner_,
        address identityRegistry_,
        address providerRegistry_,
        address serviceRegistry_,
        address sanctionsOracle_,
        address admin_
    ) internal onlyInitializing {
        require(orderSigner_ != address(0) && orderSigner_ != admin_, "invalid order signer");
        require(identityRegistry_.code.length > 0, "identity registry has no code");
        require(providerRegistry_.code.length > 0, "provider registry has no code");
        require(serviceRegistry_.code.length > 0, "service registry has no code");
        __Admin2Step_init(admin_, sanctionsOracle_);
        __EIP712_init("Daski Reputation", "1");
        orderSigner = orderSigner_;
        identityRegistry = identityRegistry_;
        providerRegistry = IProviderRegistry(providerRegistry_);
        serviceRegistry = IServiceRegistry(serviceRegistry_);
    }

    uint256[42] private __gap;
}
