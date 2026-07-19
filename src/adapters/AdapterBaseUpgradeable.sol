// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAgentIndex} from "../interfaces/IAgentIndex.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Shared adapter wiring and buyer attribution.
abstract contract AdapterBaseUpgradeable is Admin2StepUpgradeable {
    IPaymentRouter public router;
    IAgentIndex public agentIndex;

    function __AdapterBase_init(address router_, address agentIndex_, address admin_) internal onlyInitializing {
        require(router_ != address(0), "zero router");
        require(agentIndex_ != address(0), "zero agent index");
        __Admin2Step_init(admin_);
        router = IPaymentRouter(router_);
        agentIndex = IAgentIndex(agentIndex_);
    }

    function _resolveBuyer(address wallet) internal view returns (uint256 agentId) {
        bool found;
        (agentId, found) = agentIndex.resolve(wallet);
        require(found, "buyer has no agent");
    }

    function _tryResolveBuyer(address wallet) internal view returns (uint256 agentId, bool found) {
        (agentId, found) = agentIndex.resolve(wallet);
    }

    function _routerBalance(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(router));
    }

    function _requireExactFunding(address token, uint256 balanceBefore, uint256 amount) internal view {
        uint256 balanceAfter = IERC20(token).balanceOf(address(router));
        require(balanceAfter >= balanceBefore && balanceAfter - balanceBefore == amount, "unexpected token amount");
    }

    uint256[48] private _gap;
}
