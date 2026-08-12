// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockUSDC} from "./MockUSDC.sol";

/// @notice ERC-3009 test token that burns 1% of every non-mint transfer.
contract FeeOnTransferUSDC is MockUSDC {
    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount / 100;
        super._update(from, address(0), fee);
        super._update(from, to, amount - fee);
    }
}
