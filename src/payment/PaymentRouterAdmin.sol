// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAdapterBinding} from "../interfaces/IAdapterBinding.sol";
import {IReputationSink} from "../interfaces/IReputationSink.sol";
import {PaymentRouterStorage} from "./PaymentRouterStorage.sol";

/// @notice Router governance configuration.
abstract contract PaymentRouterAdmin is PaymentRouterStorage {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    function setAdapter(address adapter, bool allowed) external onlyAdmin {
        require(adapter != address(0), "zero adapter");
        if (allowed) {
            require(adapter.code.length > 0, "adapter has no code");
            _requireReputationConfigured();
            require(IAdapterBinding(adapter).router() == address(this), "wrong adapter router");
        }
        if (allowed) {
            _adapters.add(adapter);
        } else {
            _adapters.remove(adapter);
        }
        emit AdapterSet(adapter, allowed);
    }

    function setAcceptedToken(address token, bool allowed) external onlyAdmin {
        require(token != address(0), "zero token");
        if (allowed) {
            require(token.code.length > 0, "token has no code");
            require(IERC20Metadata(token).decimals() == 6, "token must have 6 decimals");
            _requireReputationConfigured();
            _acceptedTokens.add(token);
        } else {
            _acceptedTokens.remove(token);
            TokenReputationConfig storage config = _tokenReputationConfigs[token];
            if (config.enabled || config.minimumAmount != 0) {
                delete _tokenReputationConfigs[token];
                emit TokenReputationConfigured(token, false, 0);
            }
        }
        emit AcceptedTokenSet(token, allowed);
    }

    function setTokenReputationConfig(address token, bool enabled, uint256 minimumAmount) external onlyAdmin {
        require(_acceptedTokens.contains(token), "token not accepted");
        require(!enabled || minimumAmount > 0, "zero reputation minimum");
        if (!enabled) minimumAmount = 0;
        _tokenReputationConfigs[token] = TokenReputationConfig({enabled: enabled, minimumAmount: minimumAmount});
        emit TokenReputationConfigured(token, enabled, minimumAmount);
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
        require(IReputationSink(newStorage).paymentRouter() == address(this), "wrong payment router");
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
        require(!_acceptedTokens.contains(address(token)), "accepted token");
        token.safeTransfer(to, amount);
        emit ERC20Rescued(address(token), to, amount);
    }
}
