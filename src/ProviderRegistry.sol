// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// NOTE: OZ v5 removed ReentrancyGuardUpgradeable. The non-upgradeable ReentrancyGuard is
// marked @custom:stateless (uses a storage slot, no initializer) and is safe behind UUPS proxies.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";

/// @notice Daski-specific provider catalog. Now keyed by ERC-8004 agentId.
///         The Agent Card is resolved off-chain by following the agentURI in
///         the IdentityRegistry — we no longer store `agentCardURI` here.
contract ProviderRegistry is Initializable, UUPSUpgradeable, ReentrancyGuard, IProviderRegistry {
    using SafeERC20 for IERC20;

    mapping(uint256 => Provider) public _providers;
    uint256[] public providerIds;
    /// @dev DEPRECATED — set during register() in earlier versions but never
    ///      consumed. Slot retained to preserve UUPS upgrade safety; new
    ///      code does not write here.
    mapping(uint256 => uint256) public providerIndex;

    address public admin;
    address public pendingAdmin;
    address public treasury;
    IERC20 public usdc;
    IERC721 public identity;
    uint256 public listingFee;

    /// @dev Wallet → agentId reverse index. Populated on register() and
    ///      updateWalletAddress() so getProviderByAddress is O(1) instead of
    ///      a linear scan over providerIds. Appended at the end of storage
    ///      so existing slot order is preserved across UUPS upgrades.
    mapping(address => uint256) private _agentIdByWallet;

    event ProviderRegistered(uint256 indexed agentId, address indexed wallet);
    event ProviderWalletUpdated(uint256 indexed agentId, address indexed newWallet);
    event ProviderActiveStatusChanged(uint256 indexed agentId, bool isActive);
    event ListingFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

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
        require(_admin != address(0), "zero admin");
        identity = IERC721(_identity);
        usdc = IERC20(_usdc);
        treasury = _treasury;
        listingFee = _listingFee;
        admin = _admin;
    }

    function register(uint256 agentId) external nonReentrant {
        require(identity.ownerOf(agentId) == msg.sender, "not agent owner");
        require(!_isRegistered(agentId), "already registered");

        usdc.safeTransferFrom(msg.sender, treasury, listingFee);

        _providers[agentId] =
            Provider({walletAddress: msg.sender, agentId: agentId, registrationTime: block.timestamp, isActive: true});

        providerIds.push(agentId);
        _agentIdByWallet[msg.sender] = agentId;

        emit ProviderRegistered(agentId, msg.sender);
    }

    function updateWalletAddress(uint256 agentId, address newWallet) external {
        _requireAgentOwner(agentId);
        require(_isRegistered(agentId), "not registered");
        require(newWallet != address(0), "zero wallet");

        address oldWallet = _providers[agentId].walletAddress;
        if (oldWallet != newWallet) {
            // Only clear if the index still points at THIS agent — a later
            // registration with the same wallet may have overwritten it,
            // and we must not erase that newer entry.
            if (_agentIdByWallet[oldWallet] == agentId) {
                delete _agentIdByWallet[oldWallet];
            }
            _agentIdByWallet[newWallet] = agentId;
        }

        _providers[agentId].walletAddress = newWallet;
        emit ProviderWalletUpdated(agentId, newWallet);
    }

    function setActive(uint256 agentId, bool active) external {
        _requireAgentOwner(agentId);
        require(_isRegistered(agentId), "not registered");
        _providers[agentId].isActive = active;
        emit ProviderActiveStatusChanged(agentId, active);
    }

    function getProvider(uint256 agentId) external view returns (Provider memory) {
        require(_isRegistered(agentId), "not registered");
        return _providers[agentId];
    }

    function getProviderByAddress(address wallet) external view returns (Provider memory) {
        uint256 agentId = _agentIdByWallet[wallet];
        require(agentId != 0, "not registered");
        return _providers[agentId];
    }

    function getProviderCount() external view returns (uint256) {
        return providerIds.length;
    }

    /// @notice Returns up to `limit` provider agentIds starting at `offset`.
    ///         Returns an empty array if `offset >= count`. Pair with
    ///         `getProviderCount()` to walk the full list without
    ///         materializing it in a single call.
    function getProviderIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory page) {
        uint256 length = providerIds.length;
        if (offset >= length) {
            return new uint256[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        page = new uint256[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            page[i] = providerIds[offset + i];
        }
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

    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    // Internal

    function _isRegistered(uint256 agentId) internal view returns (bool) {
        return _providers[agentId].walletAddress != address(0);
    }

    function _requireAgentOwner(uint256 agentId) internal view {
        require(identity.ownerOf(agentId) == msg.sender, "not agent owner");
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
