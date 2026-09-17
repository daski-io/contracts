// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICircleUSDC {
    function decimals() external view returns (uint8);
    function paused() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
}

/// @notice Reviewed canonical Circle USDC for the two standard-rail chains,
///         Base and Base Sepolia, and the activation-readiness checks for it.
library StandardRailCircleUSDC {
    uint256 internal constant BASE_CHAIN_ID = 8_453;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function requireSupportedChain(uint256 chainId) internal pure {
        require(
            chainId == BASE_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID,
            "standard rail supports Base and Base Sepolia only"
        );
    }

    /// @notice The only token the standard rail accepts on `chainId`.
    function canonicalToken(uint256 chainId) internal pure returns (address) {
        requireSupportedChain(chainId);
        return chainId == BASE_CHAIN_ID ? BASE_USDC : BASE_SEPOLIA_USDC;
    }

    function validate(address token, address splitter, address provider, address daski) internal view {
        require(token == canonicalToken(block.chainid), "canonical token address mismatch");
        require(token.code.length != 0, "canonical token has no code");

        ICircleUSDC usdc = ICircleUSDC(token);
        require(usdc.decimals() == 6, "canonical token decimals mismatch");
        require(!usdc.paused(), "canonical token is paused");
        require(!usdc.isBlacklisted(splitter), "splitter is blacklisted");
        require(!usdc.isBlacklisted(provider), "provider is blacklisted");
        require(!usdc.isBlacklisted(daski), "Daski receiver is blacklisted");
    }
}
