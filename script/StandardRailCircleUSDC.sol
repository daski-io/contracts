// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICircleUSDC {
    function decimals() external view returns (uint8);
    function paused() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
}

/// @notice Activation-readiness checks for canonical Base Sepolia USDC.
library StandardRailCircleUSDC {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function validate(address token, address splitter, address provider, address daski) internal view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "standard Testnet rail is Base Sepolia only");
        require(token == BASE_SEPOLIA_USDC, "canonical token address mismatch");
        require(token.code.length != 0, "canonical token has no code");

        ICircleUSDC usdc = ICircleUSDC(token);
        require(usdc.decimals() == 6, "canonical token decimals mismatch");
        require(!usdc.paused(), "canonical token is paused");
        require(!usdc.isBlacklisted(splitter), "splitter is blacklisted");
        require(!usdc.isBlacklisted(provider), "provider is blacklisted");
        require(!usdc.isBlacklisted(daski), "Daski receiver is blacklisted");
    }
}
