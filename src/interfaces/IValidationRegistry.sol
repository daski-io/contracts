// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidationRegistry — namespaced, paginated validation registry interface
interface IValidationRegistry {
    event ValidationRequest(
        address indexed validatorAddress,
        uint256 indexed agentId,
        string requestURI,
        bytes32 indexed requestHash,
        bytes32 validationKey
    );

    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        bytes32 validationKey,
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

    /// @notice Distinguishes a pending request from a completed zero response.
    function hasValidationResponse(bytes32 validationKey) external view returns (bool);

    /// @notice Returns the matching count and response sum for one page.
    /// @dev Callers aggregate pages and divide the total sum by total count.
    ///      An empty validator filter includes every validator and is an
    ///      untrusted raw aggregate; it must not be treated as a trust score.
    ///      `nextOffset` is the next request-list position to scan.
    function getSummaryPaginated(
        uint256 agentId,
        address[] calldata validatorAddresses,
        string calldata tag,
        uint256 offset,
        uint256 limit
    ) external view returns (uint64 count, uint256 totalResponse, uint256 nextOffset);

    function getAgentValidationCount(uint256 agentId) external view returns (uint256);

    function getAgentValidationsPaginated(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);

    function getValidatorRequestCount(address validatorAddress) external view returns (uint256);

    function getValidatorRequestsPaginated(address validatorAddress, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory page);
}
