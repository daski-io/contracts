// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReputationSink} from "../../src/interfaces/IReputationSink.sol";

/// @notice Minimal reputation sink for payment and adapter unit tests.
contract MockReputationSink is IReputationSink {
    uint256 public paymentCount;
    uint256 public refundCount;

    function isConfigured() external pure returns (bool) {
        return true;
    }

    function recordPayment(uint256) external {
        paymentCount++;
    }

    function recordRefund(uint256, uint256) external {
        refundCount++;
    }
}
