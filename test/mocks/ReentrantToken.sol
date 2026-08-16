// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token that attempts to reenter its configured sender on transfer.
contract ReentrantToken is ERC20 {
    address public target;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() ERC20("Reentrant Token", "REENTER") {}

    function setTarget(address target_) external {
        target = target_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == target && !reentryAttempted) {
            reentryAttempted = true;
            (reentrySucceeded,) = target.call(abi.encodeWithSignature("releaseAll()"));
        }
        super._update(from, to, amount);
    }
}
