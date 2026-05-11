// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// Same pattern as PaymentRouter / ProviderRegistry: use the non-upgradeable
// ReentrancyGuard. In OZ v5 it is @custom:stateless and safe behind UUPS.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";

/// @notice Daski service catalog. Services live here as first-class records
///         keyed under an ERC-8004 provider agentId. ServiceRegistry is
///         deliberately NOT an ERC-8004 IdentityRegistry: per ERC-8004 v1
///         each agent NFT represents a *provider* (real-world operator),
///         and a single provider fields many services. A service is a row
///         in this contract, not its own NFT.
///
/// Three-layer identity model:
///   1. Provider — on-chain ERC-8004 agent NFT, identified by `agentId`.
///                 The real-world operator (e.g. "Blue T Group LLC").
///   2. Service  — on-chain row in this contract, identified by
///                 `serviceId = keccak256(providerAgentId, serviceSlug, version)`.
///                 A *marketable product* (e.g. "Domain Registration",
///                 "LLC Formation"). The unit of discovery and reputation.
///   3. Skill    — off-chain A2A AgentSkill, identified by `AgentSkill.id`
///                 (e.g. `register-domain`, `renew-domain`). A callable
///                 method. One service is implemented by **one or more**
///                 skills; the mapping lives in the off-chain `serviceURI`
///                 JSON document, NOT on-chain.
///
/// The on-chain registry knows nothing about A2A skills. The serviceURI's
/// `skills` array is a Daski convention enforced off-chain by the gateway
/// at ingest time.
///
/// Auth model — every mutating call on an existing service requires the
/// caller to be authorized over the provider's ERC-8004 NFT, matching the
/// surface used by IdentityRegistry / ReputationRegistry / ValidationRegistry:
///   1. NFT owner (ownerOf), OR
///   2. operator approved via setApprovalForAll, OR
///   3. per-token approved spender (getApproved).
contract ServiceRegistry is Initializable, UUPSUpgradeable, ReentrancyGuard, IServiceRegistry {
    // ── Storage ──────────────────────────────────────────────────────

    IERC721 public identity;
    IProviderRegistry public providerRegistry;

    mapping(bytes32 => Service) private _services;
    mapping(uint256 => bytes32[]) private _servicesByProvider;
    /// @dev Reserved for future O(1) removal-style ops; not consumed today.
    ///      Kept in storage layout to leave room without a storage gap. Reads
    ///      via the auto-getter return 0 for any serviceId because it is
    ///      never written.
    mapping(bytes32 => uint256) private _serviceIndexInProvider;

    address public admin;
    address public pendingAdmin;

    // ── Modifiers ────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identity, address _providerRegistry, address _admin) external initializer {
        require(_identity != address(0), "zero identity");
        require(_providerRegistry != address(0), "zero provider registry");
        require(_admin != address(0), "zero admin");
        identity = IERC721(_identity);
        providerRegistry = IProviderRegistry(_providerRegistry);
        admin = _admin;
    }

    // ── Service registration / management ────────────────────────────

    /// @inheritdoc IServiceRegistry
    function registerService(
        uint256 providerAgentId,
        string calldata serviceSlug,
        string calldata version,
        string calldata serviceURI,
        address serviceWallet
    ) external nonReentrant returns (bytes32 serviceId) {
        _requireAgentAuth(providerAgentId);

        // Provider must be registered AND active. Inactive providers cannot
        // add new services; existing services on an inactive provider remain
        // queryable via getService for historical lookups.
        require(providerRegistry.isRegistered(providerAgentId), "provider not registered");
        require(providerRegistry.getProvider(providerAgentId).isActive, "provider not active");

        bytes memory slugBytes = bytes(serviceSlug);
        require(slugBytes.length >= 1 && slugBytes.length <= 64, "bad serviceSlug length");
        bytes memory versionBytes = bytes(version);
        require(versionBytes.length >= 1 && versionBytes.length <= 32, "bad version length");

        serviceId = _computeServiceId(providerAgentId, serviceSlug, version);
        // Collision guard. If a service with the same (provider, slug,
        // version) already exists, registerService MUST revert — the same
        // (slug, version) pair represents the same product offering and
        // duplicating it would create ambiguity in payment routing.
        require(_services[serviceId].providerAgentId == 0, "service already registered");

        _services[serviceId] = Service({
            providerAgentId: providerAgentId,
            serviceId: serviceId,
            serviceSlug: serviceSlug,
            version: version,
            serviceURI: serviceURI,
            serviceWallet: serviceWallet,
            createdAt: uint64(block.timestamp),
            active: true
        });

        _servicesByProvider[providerAgentId].push(serviceId);

        emit ServiceRegistered(serviceId, providerAgentId, serviceSlug, version, serviceURI, serviceWallet);
    }

    /// @inheritdoc IServiceRegistry
    function updateServiceURI(bytes32 serviceId, string calldata newURI) external {
        Service storage svc = _services[serviceId];
        require(svc.providerAgentId != 0, "service not found");
        _requireAgentAuth(svc.providerAgentId);
        svc.serviceURI = newURI;
        emit ServiceURIUpdated(serviceId, newURI);
    }

    /// @inheritdoc IServiceRegistry
    /// @dev Passing `address(0)` is an explicit "clear and inherit from the
    ///      provider's ERC-8004 agentWallet at settle". Most providers will
    ///      register with serviceWallet = address(0) and never call this.
    function setServiceWallet(bytes32 serviceId, address newWallet) external {
        Service storage svc = _services[serviceId];
        require(svc.providerAgentId != 0, "service not found");
        _requireAgentAuth(svc.providerAgentId);
        svc.serviceWallet = newWallet;
        emit ServiceWalletUpdated(serviceId, newWallet);
    }

    /// @inheritdoc IServiceRegistry
    /// @dev Deactivating a service flips the flag but preserves the row so
    ///      historical payment records and reputation queries still resolve.
    ///      _servicesByProvider is append-only; deactivate does not remove.
    function setActive(bytes32 serviceId, bool active) external {
        Service storage svc = _services[serviceId];
        require(svc.providerAgentId != 0, "service not found");
        _requireAgentAuth(svc.providerAgentId);
        svc.active = active;
        emit ServiceActiveStatusChanged(serviceId, active);
    }

    // ── Views ────────────────────────────────────────────────────────

    /// @inheritdoc IServiceRegistry
    function getService(bytes32 serviceId) external view returns (Service memory) {
        Service memory svc = _services[serviceId];
        require(svc.providerAgentId != 0, "service not found");
        return svc;
    }

    /// @inheritdoc IServiceRegistry
    function isActive(bytes32 serviceId) external view returns (bool) {
        Service storage svc = _services[serviceId];
        return svc.providerAgentId != 0 && svc.active;
    }

    /// @inheritdoc IServiceRegistry
    function exists(bytes32 serviceId) external view returns (bool) {
        return _services[serviceId].providerAgentId != 0;
    }

    /// @inheritdoc IServiceRegistry
    function getServicesByProvider(uint256 providerAgentId) external view returns (bytes32[] memory) {
        return _servicesByProvider[providerAgentId];
    }

    /// @inheritdoc IServiceRegistry
    function getServicesByProviderPaginated(uint256 providerAgentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page)
    {
        bytes32[] storage all = _servicesByProvider[providerAgentId];
        uint256 length = all.length;
        if (offset >= length) {
            return new bytes32[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        page = new bytes32[](end - offset);
        for (uint256 i = 0; i < page.length; i++) {
            page[i] = all[offset + i];
        }
    }

    /// @inheritdoc IServiceRegistry
    function getServiceCountByProvider(uint256 providerAgentId) external view returns (uint256) {
        return _servicesByProvider[providerAgentId].length;
    }

    /// @inheritdoc IServiceRegistry
    function computeServiceId(uint256 providerAgentId, string calldata serviceSlug, string calldata version)
        external
        pure
        returns (bytes32)
    {
        return _computeServiceId(providerAgentId, serviceSlug, version);
    }

    function _computeServiceId(uint256 providerAgentId, string calldata serviceSlug, string calldata version)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(providerAgentId, serviceSlug, version));
    }

    // ── Auth helpers ─────────────────────────────────────────────────

    /// @dev Mirrors the auth surface in IdentityRegistry / ReputationRegistry /
    ///      ValidationRegistry: NFT owner OR operator OR per-token approved.
    function _requireAgentAuth(uint256 agentId) internal view {
        address owner = identity.ownerOf(agentId);
        require(
            msg.sender == owner || identity.isApprovedForAll(owner, msg.sender)
                || identity.getApproved(agentId) == msg.sender,
            "not owner or operator"
        );
    }

    // ── Admin / upgrade ──────────────────────────────────────────────

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

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
