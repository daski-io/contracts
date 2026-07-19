// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Daski service catalog. Services are first-class records keyed
///         under an ERC-8004 provider agentId.
///
/// A Service represents a marketable product offered by a Provider,
/// identified by a human-readable `serviceSlug` (e.g.
/// `"domain-registration"`, `"llc-formation"`). A Service is implemented
/// by **one or more** A2A skills declared in the provider's off-chain
/// Agent Card; the mapping from service to skills lives in the
/// `serviceURI` JSON document, not on-chain. The ServiceRegistry knows
/// nothing about A2A skills.
///
/// @dev    serviceId is deterministic:
///           keccak256(abi.encode(providerAgentId, serviceSlug, version))
///         so different providers can share a `serviceSlug`+`version`
///         without collision, and off-chain clients can compute the id
///         without querying the chain.
interface IServiceRegistry {
    struct Service {
        uint256 providerAgentId; // ERC-8004 agentId of the operator
        bytes32 serviceId; // keccak256(providerAgentId, serviceSlug, version)
        string serviceSlug; // category identifier, e.g. "domain-registration"
        string version; // free-form, e.g. "1", "1.0", "2025-Q1". Default "1".
        string serviceURI; // ipfs:// or https:// JSON: skills manifest, pricing, schema, etc.
        address serviceWallet; // optional override; address(0) => use provider's agentWallet
        address serviceWalletOwner; // NFT owner that authorized the override
        uint64 createdAt;
        bool active;
    }

    // ── Events ───────────────────────────────────────────────────────

    event ServiceRegistered(
        bytes32 indexed serviceId,
        uint256 indexed providerAgentId,
        string serviceSlug,
        string version,
        string serviceURI,
        address serviceWallet
    );
    event ServiceURIUpdated(bytes32 indexed serviceId, string newURI);
    event ServiceWalletUpdated(bytes32 indexed serviceId, address newWallet);
    event ServiceActiveStatusChanged(bytes32 indexed serviceId, bool active);

    // ── Mutating ─────────────────────────────────────────────────────

    /// @param providerAgentId ERC-8004 agentId of the provider this service
    ///        belongs to. Caller must be the NFT owner or an ERC-721 operator
    ///        approved for the provider's NFT.
    /// @param serviceSlug     Human-readable service category identifier
    ///                        (1–64 bytes). NOT an A2A skill id — that lives
    ///                        in the off-chain serviceURI JSON's `skills`
    ///                        array. Convention: lowercase-kebab
    ///                        (`"domain-registration"`).
    /// @param version         Free-form, e.g. "1" or "2025-Q1" (1–32 bytes).
    /// @param serviceURI      JSON describing pricing/schema/skills manifest.
    /// @param serviceWallet   Optional payee override. address(0) => inherit
    ///                        the provider's ERC-8004 agentWallet at settle.
    function registerService(
        uint256 providerAgentId,
        string calldata serviceSlug,
        string calldata version,
        string calldata serviceURI,
        address serviceWallet
    ) external returns (bytes32 serviceId);

    function updateServiceURI(bytes32 serviceId, string calldata newURI) external;
    function setServiceWallet(bytes32 serviceId, address newWallet) external;
    function setActive(bytes32 serviceId, bool active) external;

    // ── Views ────────────────────────────────────────────────────────

    function getService(bytes32 serviceId) external view returns (Service memory);
    function isActive(bytes32 serviceId) external view returns (bool);
    function exists(bytes32 serviceId) external view returns (bool);
    function getServicesByProvider(uint256 providerAgentId) external view returns (bytes32[] memory);
    function getServicesByProviderPaginated(uint256 providerAgentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);
    function getServiceCountByProvider(uint256 providerAgentId) external view returns (uint256);

    /// @notice Helper for off-chain clients. MUST match the on-chain
    ///         derivation in `registerService`.
    function computeServiceId(uint256 providerAgentId, string calldata serviceSlug, string calldata version)
        external
        pure
        returns (bytes32);
}
