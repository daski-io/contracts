// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IServiceRegistry} from "../interfaces/IServiceRegistry.sol";
import {PaymentRouterStorage} from "./PaymentRouterStorage.sol";

/// @notice Router views and governance configuration.
abstract contract PaymentRouterAdmin is PaymentRouterStorage {
    using SafeERC20 for IERC20;

    function quoteCommission(uint256 amount) external view returns (uint256 commission, uint256 providerAmount) {
        commission = (amount * commissionBps) / 10000;
        providerAmount = amount - commission;
    }

    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory) {
        require(_payments[paymentId].amount > 0, "payment not found");
        return _payments[paymentId];
    }

    function refundedAmount(uint256 paymentId) external view returns (uint256) {
        return _refundedAmount[paymentId];
    }

    function serviceRefUsed(bytes32 serviceRef) external view returns (bool) {
        return _usedServiceRefs[serviceRef];
    }

    function isAdapter(address adapter) external view returns (bool) {
        return adapters[adapter];
    }

    function isAcceptedToken(address token) external view returns (bool) {
        return acceptedTokens[token];
    }

    function reservedBalance(address token) external view returns (uint256) {
        return _reservedBalances[token];
    }

    function setAdapter(address adapter, bool allowed) external onlyAdmin {
        require(adapter != address(0), "zero adapter");
        adapters[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function setAcceptedToken(address token, bool allowed) external onlyAdmin {
        require(token != address(0), "zero token");
        acceptedTokens[token] = allowed;
        emit AcceptedTokenSet(token, allowed);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), "zero treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setReputationStorage(address newStorage) external onlyAdmin {
        require(nextPaymentId == 1, "payments already exist");
        address oldStorage = reputationStorage;
        reputationStorage = newStorage;
        emit ReputationStorageUpdated(oldStorage, newStorage);
    }

    function setServiceRegistry(address newRegistry) external onlyAdmin {
        require(nextPaymentId == 1, "payments already exist");
        require(newRegistry != address(0), "zero service registry");
        address old = address(serviceRegistry);
        serviceRegistry = IServiceRegistry(newRegistry);
        emit ServiceRegistryUpdated(old, newRegistry);
    }

    function setCommissionBps(uint256 newBps) external onlyAdmin {
        require(newBps <= 10000, "commission too high");
        uint256 oldBps = commissionBps;
        commissionBps = newBps;
        emit CommissionUpdated(oldBps, newBps);
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "zero to");
        require(!acceptedTokens[address(token)], "accepted token");
        require(token.balanceOf(address(this)) >= _reservedBalances[address(token)] + amount, "reserved funds");
        token.safeTransfer(to, amount);
        emit ERC20Rescued(address(token), to, amount);
    }

    function _reservationKey(address adapter, bytes32 depositId) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapter, depositId));
    }
}
