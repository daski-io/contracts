// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICanonicalIdentity} from "../interfaces/ICanonicalIdentity.sol";
import {IProviderRegistry} from "../interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "../interfaces/IServiceRegistry.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Storage and events shared by the router's operational and
///         administrative surfaces.
abstract contract PaymentRouterStorage is Admin2StepUpgradeable, ReentrancyGuard, IPaymentRouter {
    address public treasury;
    ICanonicalIdentity public identity;
    IProviderRegistry public registry;
    uint256 public commissionBps;
    uint256 public nextPaymentId;

    mapping(uint256 => PaymentRecord) internal _payments;
    mapping(bytes32 => bool) internal _usedServiceRefs;
    mapping(address => bool) public adapters;
    mapping(address => bool) public acceptedTokens;
    mapping(uint256 => uint256) internal _refundedAmount;

    address public reputationStorage;
    IServiceRegistry public serviceRegistry;

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
    event CommissionUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ReputationStorageUpdated(address indexed oldStorage, address indexed newStorage);
    event ServiceRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    modifier onlyAdapter() {
        require(adapters[msg.sender], "not adapter");
        _;
    }

    uint256[50] private _gap;
}
