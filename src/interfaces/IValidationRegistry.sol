// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidationRegistry — ERC-8004 Validation Registry interface
/// @notice Pinned to ERC-8004 draft spec commit
///         503591a6e80e6e1affdd6403341e25269141f046.
///
/// Daski hardening (audit L-2): records are keyed by
/// `validationKey = keccak256(agentId, requestHash)` rather than the raw
/// `requestHash`, removing the cross-agent request-hash squatting vector.
/// `validationRequest` returns the key; `validationResponse` and the read views
/// take it; `computeValidationKey` re-derives it off-chain. The request/response
/// events still carry the human-meaningful `requestHash`.
interface IValidationRegistry {
    event ValidationRequest(
        address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash
    );

    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );

    function getIdentityRegistry() external view returns (address identityRegistry);

    /// @notice Register a validation request for `agentId`. Caller MUST be the
    ///         owner or operator of `agentId`.
    /// @return validationKey keccak256(agentId, requestHash) — the handle used
    ///         by `validationResponse` and the read views.
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external returns (bytes32 validationKey);

    /// @notice Submit (or overwrite) the response for `validationKey`. Caller
    ///         MUST be the validator named in the request.
    function validationResponse(
        bytes32 validationKey,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    function getValidationStatus(bytes32 validationKey)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            bytes32 requestHash,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );

    /// @notice Re-derive the validationKey for `(agentId, requestHash)`. MUST
    ///         match the on-chain derivation in `validationRequest`.
    function computeValidationKey(uint256 agentId, bytes32 requestHash) external pure returns (bytes32);

    /// @notice Returns the validationKeys requested for `agentId`.
    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory validationKeys);

    function getAgentValidationCount(uint256 agentId) external view returns (uint256);

    function getAgentValidationsPaginated(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);

    /// @notice Returns the validationKeys assigned to `validatorAddress`.
    function getValidatorRequests(address validatorAddress) external view returns (bytes32[] memory validationKeys);

    function getValidatorRequestCount(address validatorAddress) external view returns (uint256);

    function getValidatorRequestsPaginated(address validatorAddress, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);
}
