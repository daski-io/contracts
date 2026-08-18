// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Six-decimal Circle-style token used for release-tooling and liveness tests.
contract MockCircleUSDC is ERC20 {
    bool public paused;
    address public pauser = address(0x1001);
    address public blacklister = address(0x1002);
    address public implementation;
    mapping(address account => bool blacklisted) private _blacklisted;

    constructor() ERC20("USDC", "USDC") {
        implementation = address(this);
    }

    function currency() external pure returns (string memory) {
        return "USD";
    }

    function version() external pure returns (string memory) {
        return "2";
    }

    function decimals() public pure override returns (uint8) {
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

    function setImplementation(address value) external {
        implementation = value;
    }

    function setPauser(address value) external {
        pauser = value;
    }

    function setBlacklister(address value) external {
        blacklister = value;
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
