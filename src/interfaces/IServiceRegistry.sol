// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Daski service catalog. Services are first-class records keyed
///         under an ERC-8004 provider agentId. A service is NOT itself an
///         agent: the on-chain identity that fields the service is the
///         provider, and a single provider can register many services.
/// @dev    serviceId is deterministic:
///           keccak256(abi.encodePacked(providerAgentId, skillId, version))
///         so different providers can share a `skillId`+`version` without
///         collision and so off-chain clients can compute the id without
///         querying the chain.
interface IServiceRegistry {
    struct Service {
        uint256 providerAgentId; // ERC-8004 agentId of the operator
        bytes32 serviceId; // keccak256(providerAgentId, skillId, version)
        string skillId; // matches AgentSkill.id in the provider's A2A Agent Card
        string version; // free-form, e.g. "1", "1.0", "2025-Q1". Default "1".
        string serviceURI; // ipfs:// or https:// JSON: schema, pricing, requiredFields, etc.
        address serviceWallet; // optional override; address(0) => use provider's agentWallet
        uint64 createdAt;
        bool active;
    }

    // ── Events ───────────────────────────────────────────────────────

    event ServiceRegistered(
        bytes32 indexed serviceId,
        uint256 indexed providerAgentId,
        string skillId,
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
    /// @param skillId         Matches AgentSkill.id in the provider's A2A
    ///                        Agent Card (1–64 bytes).
    /// @param version         Free-form, e.g. "1" or "2025-Q1" (1–32 bytes).
    /// @param serviceURI      JSON describing schema/pricing/required fields.
    /// @param serviceWallet   Optional payee override. address(0) => inherit
    ///                        the provider's ERC-8004 agentWallet at settle.
    function registerService(
        uint256 providerAgentId,
        string calldata skillId,
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
    function computeServiceId(uint256 providerAgentId, string calldata skillId, string calldata version)
        external
        pure
        returns (bytes32);
}
