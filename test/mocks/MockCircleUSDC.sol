// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Six-decimal token with Circle-style pause and blacklist controls.
contract MockCircleUSDC is ERC20 {
    bool public paused;
    mapping(address account => bool blacklisted) private _blacklisted;

    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlacklisted(address account, bool value) external {
        _blacklisted[account] = value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "FiatToken: token is paused");
        require(!_blacklisted[from] && !_blacklisted[to], "FiatToken: account is blacklisted");
        super._update(from, to, value);
    }
}
