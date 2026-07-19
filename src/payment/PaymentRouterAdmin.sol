// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IReputationSink} from "../interfaces/IReputationSink.sol";
import {PaymentRouterStorage} from "./PaymentRouterStorage.sol";

/// @notice Router governance configuration.
abstract contract PaymentRouterAdmin is PaymentRouterStorage {
    using SafeERC20 for IERC20;

    function setAdapter(address adapter, bool allowed) external onlyAdmin {
        require(adapter != address(0), "zero adapter");
        if (allowed) {
            require(adapter.code.length > 0, "adapter has no code");
            _requireReputationConfigured();
        }
        _adapters[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function setAcceptedToken(address token, bool allowed) external onlyAdmin {
        require(token != address(0), "zero token");
        if (allowed) {
            require(token.code.length > 0, "token has no code");
            _requireReputationConfigured();
        }
        _acceptedTokens[token] = allowed;
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
        require(newStorage != address(0), "zero reputation storage");
        require(newStorage.code.length > 0, "reputation storage has no code");
        require(IReputationSink(newStorage).isConfigured(), "reputation not configured");
        address oldStorage = reputationStorage;
        reputationStorage = newStorage;
        emit ReputationStorageUpdated(oldStorage, newStorage);
    }

    function setCommissionBps(uint256 newBps) external onlyAdmin {
        require(newBps <= 10000, "commission too high");
        uint256 oldBps = commissionBps;
        commissionBps = newBps;
        emit CommissionUpdated(oldBps, newBps);
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "zero to");
        require(!_acceptedTokens[address(token)], "accepted token");
        token.safeTransfer(to, amount);
        emit ERC20Rescued(address(token), to, amount);
    }
}
