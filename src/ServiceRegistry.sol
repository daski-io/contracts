// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICanonicalIdentity} from "./interfaces/ICanonicalIdentity.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {LibPagination} from "./utils/LibPagination.sol";

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
contract ServiceRegistry is Admin2StepUpgradeable, IServiceRegistry {
    // ── Storage ──────────────────────────────────────────────────────

    ICanonicalIdentity public identity;
    IProviderRegistry public providerRegistry;

    mapping(bytes32 => Service) private _services;
    mapping(bytes32 => bool) private _serviceExists;
    mapping(uint256 => bytes32[]) private _servicesByProvider;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identity, address _providerRegistry, address _admin) external initializer {
        require(_identity != address(0), "zero identity");
        require(_providerRegistry != address(0), "zero provider registry");
        __Admin2Step_init(_admin);
        identity = ICanonicalIdentity(_identity);
        providerRegistry = IProviderRegistry(_providerRegistry);
    }

    // ── Service registration / management ────────────────────────────

    /// @inheritdoc IServiceRegistry
    function registerService(
        uint256 providerAgentId,
        string calldata serviceSlug,
        string calldata version,
        string calldata serviceURI,
        address serviceWallet
    ) external returns (bytes32 serviceId) {
        LibAgentAuth.requireAgentAuth(identity, providerAgentId, msg.sender);

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
        require(!_serviceExists[serviceId], "service already registered");

        _services[serviceId] = Service({
            providerAgentId: providerAgentId,
            serviceId: serviceId,
            serviceSlug: serviceSlug,
            version: version,
            serviceURI: serviceURI,
            serviceWallet: address(0),
            serviceWalletOwner: address(0),
            serviceWalletAgentWallet: address(0),
            createdAt: uint64(block.timestamp),
            active: true
        });
        _setServiceWalletAuthorization(_services[serviceId], serviceWallet);
        _serviceExists[serviceId] = true;

        _servicesByProvider[providerAgentId].push(serviceId);

        emit ServiceRegistered(serviceId, providerAgentId, serviceSlug, version, serviceURI, serviceWallet);
    }

    /// @inheritdoc IServiceRegistry
    function updateServiceURI(bytes32 serviceId, string calldata newURI) external {
        Service storage svc = _services[serviceId];
        require(_serviceExists[serviceId], "service not found");
        LibAgentAuth.requireAgentAuth(identity, svc.providerAgentId, msg.sender);
        svc.serviceURI = newURI;
        emit ServiceURIUpdated(serviceId, newURI);
    }

    /// @inheritdoc IServiceRegistry
    /// @dev Passing `address(0)` is an explicit "clear and inherit from the
    ///      provider's ERC-8004 agentWallet at settle". Most providers will
    ///      register with serviceWallet = address(0) and never call this.
    ///      Non-zero overrides are valid only while the authorizing owner and
    ///      agentWallet both remain current.
    function setServiceWallet(bytes32 serviceId, address newWallet) external {
        Service storage svc = _services[serviceId];
        require(_serviceExists[serviceId], "service not found");
        LibAgentAuth.requireAgentAuth(identity, svc.providerAgentId, msg.sender);
        _setServiceWalletAuthorization(svc, newWallet);
        emit ServiceWalletUpdated(serviceId, newWallet);
    }

    /// @inheritdoc IServiceRegistry
    /// @dev Deactivating a service flips the flag but preserves the row so
    ///      historical payment records and reputation queries still resolve.
    ///      _servicesByProvider is append-only; deactivate does not remove.
    function setActive(bytes32 serviceId, bool active) external {
        Service storage svc = _services[serviceId];
        require(_serviceExists[serviceId], "service not found");
        LibAgentAuth.requireAgentAuth(identity, svc.providerAgentId, msg.sender);
        svc.active = active;
        emit ServiceActiveStatusChanged(serviceId, active);
    }

    // ── Views ────────────────────────────────────────────────────────

    /// @inheritdoc IServiceRegistry
    function getService(bytes32 serviceId) external view returns (Service memory) {
        Service memory svc = _services[serviceId];
        require(_serviceExists[serviceId], "service not found");
        return svc;
    }

    /// @inheritdoc IServiceRegistry
    function resolveSettlement(bytes32 serviceId)
        external
        view
        returns (uint256 providerAgentId, bool active, address providerOwner, address providerWallet, address payee)
    {
        Service storage svc = _services[serviceId];
        require(_serviceExists[serviceId], "service not found");

        providerAgentId = svc.providerAgentId;
        active = svc.active;
        providerOwner = identity.ownerOf(providerAgentId);
        providerWallet = identity.getAgentWallet(providerAgentId);
        bool overrideCurrent = svc.serviceWallet != address(0) && svc.serviceWalletOwner == providerOwner
            && svc.serviceWalletAgentWallet != address(0) && svc.serviceWalletAgentWallet == providerWallet;
        payee = overrideCurrent ? svc.serviceWallet : providerWallet;
    }

    /// @inheritdoc IServiceRegistry
    function isActive(bytes32 serviceId) external view returns (bool) {
        Service storage svc = _services[serviceId];
        return _serviceExists[serviceId] && svc.active;
    }

    /// @inheritdoc IServiceRegistry
    function exists(bytes32 serviceId) external view returns (bool) {
        return _serviceExists[serviceId];
    }

    /// @inheritdoc IServiceRegistry
    function getServicesByProviderPaginated(uint256 providerAgentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        return LibPagination.paginate(_servicesByProvider[providerAgentId], offset, limit);
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
        return keccak256(abi.encode(providerAgentId, serviceSlug, version));
    }

    function _setServiceWalletAuthorization(Service storage svc, address newWallet) internal {
        svc.serviceWallet = newWallet;
        if (newWallet == address(0)) {
            svc.serviceWalletOwner = address(0);
            svc.serviceWalletAgentWallet = address(0);
            return;
        }

        address agentWallet = identity.getAgentWallet(svc.providerAgentId);
        require(agentWallet != address(0), "no agent wallet");
        svc.serviceWalletOwner = identity.ownerOf(svc.providerAgentId);
        svc.serviceWalletAgentWallet = agentWallet;
    }

    uint256[50] private __gap;
}
