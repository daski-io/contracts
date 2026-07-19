// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidationRegistry — ERC-8004 Validation Registry interface
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

    function computeValidationKey(uint256 agentId, bytes32 requestHash) external pure returns (bytes32 validationKey);

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
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );

    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        returns (uint64 count, uint8 averageResponse);

    /// @notice Returns namespaced validation keys requested for `agentId`.
    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory validationKeys);

    function getAgentValidationCount(uint256 agentId) external view returns (uint256);

    function getAgentValidationsPaginated(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);

    /// @notice Returns namespaced validation keys assigned to `validatorAddress`.
    function getValidatorRequests(address validatorAddress) external view returns (bytes32[] memory validationKeys);

    function getValidatorRequestCount(address validatorAddress) external view returns (uint256);

    function getValidatorRequestsPaginated(address validatorAddress, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);
}
