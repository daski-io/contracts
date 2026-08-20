// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// NOTE: OZ v5 removed ReentrancyGuardUpgradeable. The non-upgradeable ReentrancyGuard is
// marked @custom:stateless (uses a storage slot, no initializer) and is safe behind UUPS proxies.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICanonicalIdentity} from "./interfaces/ICanonicalIdentity.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {LibDependencyValidation} from "./utils/LibDependencyValidation.sol";
import {LibPagination} from "./utils/LibPagination.sol";

/// @notice Daski-specific provider gate. A "provider" is the real-world
///         operator (Blue T Group LLC, etc.) — identified by an ERC-8004
///         agent NFT in the CANONICAL per-chain IdentityRegistry (the
///         0x8004A... singleton; Daski deploys no identity registry of its
///         own), with a row here marking it as an active Daski provider.
///         Services offered by the provider live in the separate Daski
///         `ServiceRegistry`. Per ERC-8004 v1, each NFT represents one
///         operator that may field many capabilities; do NOT re-introduce a
///         per-service NFT pattern.
///
/// Wallet model: this registry stores no wallet. The payee surface is the
/// canonical registry's `agentWallet` (service attribution and provider
/// authorization read it live; providers MUST verify one there before they can
/// be paid or authorize a per-service serviceWallet). Wallet→agent
/// reverse lookup lives separately in the Daski `AgentIndex`; callers use
/// explicit agentIds with this registry.
///
/// Auth model on mutating functions other than `register`: the caller must be
/// the NFT owner, an ERC-721 operator (`isApprovedForAll`), or per-token
/// approved spender (`getApproved`) — matching the surface used in the rest
/// of the stack. `register(agentId)` stays strict on `ownerOf` because
/// listing is a one-time act of consent that should require the actual key.
contract ProviderRegistry is Admin2StepUpgradeable, ReentrancyGuard, IProviderRegistry {
    using SafeERC20 for IERC20;

    mapping(uint256 => Provider) internal _providers;
    mapping(uint256 => bool) private _registered;
    uint256[] public providerIds;

    address public treasury;
    IERC20 public usdc;
    ICanonicalIdentity public identity;
    uint256 public listingFee;

    event ProviderRegistered(uint256 indexed agentId, address indexed wallet);
    event ProviderActiveStatusChanged(uint256 indexed agentId, bool isActive);
    event ListingFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _identity,
        address _usdc,
        address _treasury,
        uint256 _listingFee,
        address _sanctionsOracle,
        address _admin
    ) external initializer {
        require(_identity != address(0), "zero identity");
        require(_usdc != address(0), "zero usdc");
        require(_treasury != address(0), "zero treasury");
        LibDependencyValidation.requireIdentity(_identity);
        LibDependencyValidation.requireUsdc(_usdc);
        __Admin2Step_init(_admin, _sanctionsOracle);
        identity = ICanonicalIdentity(_identity);
        usdc = IERC20(_usdc);
        _requireNotSanctioned(_treasury);
        treasury = _treasury;
        listingFee = _listingFee;
    }

    function register(uint256 agentId) external nonReentrant whenExternalDependencyOperational {
        require(identity.ownerOf(agentId) == msg.sender, "not agent owner");
        require(!_isRegistered(agentId), "already registered");
        _requireNotSanctioned(msg.sender);
        _requireNotSanctioned(treasury);

        uint256 balanceBefore = usdc.balanceOf(treasury);
        usdc.safeTransferFrom(msg.sender, treasury, listingFee);
        uint256 balanceAfter = usdc.balanceOf(treasury);
        require(balanceAfter >= balanceBefore && balanceAfter - balanceBefore == listingFee, "unexpected listing fee");

        _providers[agentId] = Provider({agentId: agentId, registrationTime: block.timestamp, isActive: true});
        _registered[agentId] = true;

        providerIds.push(agentId);

        emit ProviderRegistered(agentId, msg.sender);
    }

    function setActive(uint256 agentId, bool active) external whenExternalDependencyOperational {
        LibAgentAuth.requireAgentAuth(identity, agentId, msg.sender);
        require(_isRegistered(agentId), "not registered");
        _requireAgentParticipantsAllowed(msg.sender, identity.ownerOf(agentId), identity.getAgentWallet(agentId));
        _providers[agentId].isActive = active;
        emit ProviderActiveStatusChanged(agentId, active);
    }

    function getProvider(uint256 agentId) external view returns (Provider memory) {
        require(_isRegistered(agentId), "not registered");
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
        _requireNotSanctioned(newTreasury);
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    // Internal

    function _isRegistered(uint256 agentId) internal view returns (bool) {
        return _registered[agentId];
    }

    uint256[50] private __gap;
}
