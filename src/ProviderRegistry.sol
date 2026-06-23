// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// NOTE: OZ v5 removed ReentrancyGuardUpgradeable. The non-upgradeable ReentrancyGuard is
// marked @custom:stateless (uses a storage slot, no initializer) and is safe behind UUPS proxies.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {LibPagination} from "./utils/LibPagination.sol";

/// @notice Daski-specific provider gate. A "provider" is the real-world
///         operator (Blue T Group LLC, etc.) — identified by an ERC-8004
///         agent NFT in IdentityRegistry, with a row here marking it as an
///         active Daski provider. Services offered by the provider live in
///         the separate Daski `ServiceRegistry`. Per ERC-8004 v1, each NFT
///         represents one operator that may field many capabilities; do NOT
///         re-introduce a per-service NFT pattern.
///
/// Wallet model: this registry no longer stores a Daski-local wallet. The
/// canonical payee/identity surface is the ERC-8004 `agentWallet` in
/// IdentityRegistry (used by PaymentRouter and refund auth), and wallet→agent
/// resolution goes through `IdentityRegistry.agentOfWallet`.
///
/// Auth model on mutating functions other than `register`: the caller must be
/// the NFT owner, an ERC-721 operator (`isApprovedForAll`), or per-token
/// approved spender (`getApproved`) — matching the surface used in the rest
/// of the stack. `register(agentId)` stays strict on `ownerOf` because
/// listing is a one-time act of consent that should require the actual key.
contract ProviderRegistry is Admin2StepUpgradeable, ReentrancyGuard, IProviderRegistry {
    using SafeERC20 for IERC20;

    mapping(uint256 => Provider) internal _providers;
    uint256[] public providerIds;

    address public treasury;
    IERC20 public usdc;
    IERC721 public identity;
    uint256 public listingFee;

    event ProviderRegistered(uint256 indexed agentId, address indexed wallet);
    event ProviderActiveStatusChanged(uint256 indexed agentId, bool isActive);
    event ListingFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identity, address _usdc, address _treasury, uint256 _listingFee, address _admin)
        external
        initializer
    {
        require(_identity != address(0), "zero identity");
        require(_usdc != address(0), "zero usdc");
        require(_treasury != address(0), "zero treasury");
        __Admin2Step_init(_admin);
        identity = IERC721(_identity);
        usdc = IERC20(_usdc);
        treasury = _treasury;
        listingFee = _listingFee;
    }

    function register(uint256 agentId) external nonReentrant {
        require(identity.ownerOf(agentId) == msg.sender, "not agent owner");
        require(!_isRegistered(agentId), "already registered");

        usdc.safeTransferFrom(msg.sender, treasury, listingFee);

        _providers[agentId] = Provider({agentId: agentId, registrationTime: block.timestamp, isActive: true});

        providerIds.push(agentId);

        emit ProviderRegistered(agentId, msg.sender);
    }

    function setActive(uint256 agentId, bool active) external {
        LibAgentAuth.requireAgentAuth(identity, agentId, msg.sender);
        require(_isRegistered(agentId), "not registered");
        _providers[agentId].isActive = active;
        emit ProviderActiveStatusChanged(agentId, active);
    }

    function getProvider(uint256 agentId) external view returns (Provider memory) {
        require(_isRegistered(agentId), "not registered");
        return _providers[agentId];
    }

    function getProviderByAddress(address wallet) external view returns (Provider memory) {
        // Resolve through the canonical ERC-8004 reverse index rather than a
        // Daski-local wallet copy. agentOfWallet returns the agent whose
        // CURRENT agentWallet is `wallet` (cleared on transfer / rotation).
        uint256 agentId = IdentityRegistry(address(identity)).agentOfWallet(wallet);
        require(agentId != 0 && _isRegistered(agentId), "not registered");
        return _providers[agentId];
    }

    function getProviderCount() external view returns (uint256) {
        return providerIds.length;
    }

    /// @notice Returns up to `limit` provider agentIds starting at `offset`.
    ///         Returns an empty array if `offset >= count`. Pair with
    ///         `getProviderCount()` to walk the full list without
    ///         materializing it in a single call.
    function getProviderIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return LibPagination.paginate(providerIds, offset, limit);
    }

    function isRegistered(uint256 agentId) external view returns (bool) {
        return _isRegistered(agentId);
    }

    // Admin functions

    function setListingFee(uint256 newFee) external onlyAdmin {
        uint256 oldFee = listingFee;
        listingFee = newFee;
        emit ListingFeeUpdated(oldFee, newFee);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), "zero treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    // Internal

    function _isRegistered(uint256 agentId) internal view returns (bool) {
        return _providers[agentId].agentId != 0;
    }

    uint256[50] private __gap;
}
