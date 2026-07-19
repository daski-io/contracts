// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

    uint256[48] private _gap;
}
