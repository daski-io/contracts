// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ICanonicalIdentity} from "../interfaces/ICanonicalIdentity.sol";
import {IProviderRegistry} from "../interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "../interfaces/IServiceRegistry.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IReputationSink} from "../interfaces/IReputationSink.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Storage and events shared by the router's operational and
///         administrative surfaces.
abstract contract PaymentRouterStorage is Admin2StepUpgradeable, ReentrancyGuard, IPaymentRouter {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct TokenReputationConfig {
        bool enabled;
        uint256 minimumAmount;
    }

    address public treasury;
    ICanonicalIdentity public identity;
    IProviderRegistry public registry;
    uint256 public commissionBps;
    uint256 public nextPaymentId;

    mapping(uint256 => PaymentRecord) internal _payments;
    mapping(bytes32 => bool) internal _usedPaymentKeys;
    EnumerableSet.AddressSet internal _adapters;
    EnumerableSet.AddressSet internal _acceptedTokens;
    mapping(uint256 => uint256) internal _refundedAmount;
    mapping(uint256 => bool) internal _reputationPaymentSynced;
    mapping(uint256 => uint256) internal _reputationRefundSynced;

    address public reputationStorage;
    IServiceRegistry public serviceRegistry;
    mapping(address => TokenReputationConfig) internal _tokenReputationConfigs;

    event PaymentSettled(
        uint256 indexed paymentId,
        bytes32 indexed serviceRef,
        bytes32 indexed serviceId,
        uint256 buyerAgentId,
        uint256 providerAgentId,
        address token,
        uint256 totalAmount,
        uint256 providerAmount,
        uint256 commission
    );
    event Refunded(uint256 indexed paymentId, uint256 amountToBuyer, uint256 cumulativeRefunded);
    event AdapterSet(address indexed adapter, bool allowed);
    event AcceptedTokenSet(address indexed token, bool allowed);
    event TokenReputationConfigured(address indexed token, bool enabled, uint256 minimumAmount);
    event CommissionUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ReputationStorageUpdated(address indexed oldStorage, address indexed newStorage);
    event ReputationPaymentSynced(uint256 indexed paymentId);
    event ReputationRefundSynced(uint256 indexed paymentId, uint256 amount, uint256 cumulativeAmount);
    event ReputationSyncFailed(uint256 indexed paymentId, bytes4 indexed operation);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    modifier onlyAdapter() {
        require(_adapters.contains(msg.sender), "not adapter");
        _;
    }

    function _paymentKey(uint256 buyerAgentId, uint256 providerAgentId, bytes32 serviceId, bytes32 serviceRef)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(buyerAgentId, providerAgentId, serviceId, serviceRef));
    }

    function _requireReputationConfigured() internal view {
        require(reputationStorage.code.length > 0, "reputation not configured");
        require(IReputationSink(reputationStorage).isConfigured(), "reputation not configured");
    }

    uint256[49] private _gap;
}
