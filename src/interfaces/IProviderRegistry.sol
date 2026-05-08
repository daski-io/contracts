// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Daski-specific provider metadata. The provider's Agent Card is
///         resolved off-chain from the ERC-8004 IdentityRegistry (agentURI
///         → agent registration file → services array), so there is no
///         `agentCardURI` on this struct anymore.
interface IProviderRegistry {
    struct Provider {
        address walletAddress;
        uint256 agentId;
        uint256 registrationTime;
        bool isActive;
    }

    /// @param agentId ERC-8004 agentId to register as a Daski provider. The
    ///        caller MUST be the ERC-721 owner of agentId.
    function register(uint256 agentId) external;
    function updateWalletAddress(uint256 agentId, address newWallet) external;
    function setActive(uint256 agentId, bool active) external;
    function getProvider(uint256 agentId) external view returns (Provider memory);
    function getProviderByAddress(address wallet) external view returns (Provider memory);
    function getProviderCount() external view returns (uint256);
    function getProviderIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory page);
    function isRegistered(uint256 agentId) external view returns (bool);
}
