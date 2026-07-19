// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidationRegistry} from "./interfaces/IValidationRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {LibPagination} from "./utils/LibPagination.sol";

/// @notice ERC-8004 Validation Registry. Stores the latest response
///         per validation (the spec allows multiple calls; each overwrites
///         response/responseHash/tag and bumps lastUpdate — the full history
///         is recoverable from events). Daski namespaces storage handles by
///         agentId to prevent cross-agent request-hash squatting.
contract ValidationRegistry is Admin2StepUpgradeable, IValidationRegistry {
    struct Validation {
        address validatorAddress;
        uint256 agentId;
        bytes32 requestHash;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
        bool exists;
        bool hasResponse;
    }

    IERC721 public identityRegistry;

    // validationKey = keccak256(agentId, requestHash).
    mapping(bytes32 => Validation) private _validations;
    mapping(uint256 => bytes32[]) private _agentRequests;
    mapping(address => bytes32[]) private _validatorRequests;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address identityRegistry_, address _admin) external initializer {
        require(identityRegistry_ != address(0), "zero identity");
        __Admin2Step_init(_admin);
        identityRegistry = IERC721(identityRegistry_);
    }

    function getIdentityRegistry() external view override returns (address) {
        return address(identityRegistry);
    }

    function computeValidationKey(uint256 agentId, bytes32 requestHash) external pure override returns (bytes32) {
        return _validationKey(agentId, requestHash);
    }

    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external override returns (bytes32 validationKey) {
        // Spec: MUST be called by owner or operator of agentId.
        LibAgentAuth.requireAgentAuth(identityRegistry, agentId, msg.sender);
        require(validatorAddress != address(0), "zero validator");
        require(bytes(requestURI).length != 0, "empty request URI");
        require(requestHash != bytes32(0), "zero request hash");

        validationKey = _validationKey(agentId, requestHash);
        require(!_validations[validationKey].exists, "request exists");

        _validations[validationKey] = Validation({
            validatorAddress: validatorAddress,
            agentId: agentId,
            requestHash: requestHash,
            response: 0,
            responseHash: bytes32(0),
            tag: "",
            lastUpdate: block.timestamp,
            exists: true,
            hasResponse: false
        });

        _agentRequests[agentId].push(validationKey);
        _validatorRequests[validatorAddress].push(validationKey);

        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    function validationResponse(
        bytes32 validationKey,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external override {
        Validation storage v = _validations[validationKey];
        require(v.exists, "no such request");
        require(msg.sender == v.validatorAddress, "not validator");
        require(response <= 100, "response > 100");

        v.response = response;
        v.responseHash = responseHash;
        v.tag = tag;
        v.lastUpdate = block.timestamp;
        v.hasResponse = true;

        emit ValidationResponse(v.validatorAddress, v.agentId, v.requestHash, response, responseURI, responseHash, tag);
    }

    function getValidationStatus(bytes32 validationKey)
        external
        view
        override
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        Validation storage v = _validations[validationKey];
        require(v.exists, "no such request");
        return (v.validatorAddress, v.agentId, v.response, v.responseHash, v.tag, v.lastUpdate);
    }

    function hasValidationResponse(bytes32 validationKey) external view override returns (bool) {
        Validation storage v = _validations[validationKey];
        require(v.exists, "no such request");
        return v.hasResponse;
    }

    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        override
        returns (uint64 count, uint8 averageResponse)
    {
        uint256 total;
        (count, total,) = _summaryPage(agentId, validatorAddresses, tag, 0, _agentRequests[agentId].length);
        if (count != 0) {
            averageResponse = SafeCast.toUint8(total / count);
        }
    }

    function getSummaryPaginated(
        uint256 agentId,
        address[] calldata validatorAddresses,
        string calldata tag,
        uint256 offset,
        uint256 limit
    ) external view override returns (uint64 count, uint256 totalResponse, uint256 nextOffset) {
        return _summaryPage(agentId, validatorAddresses, tag, offset, limit);
    }

    function getAgentValidations(uint256 agentId) external view override returns (bytes32[] memory) {
        return _agentRequests[agentId];
    }

    function getValidatorRequests(address validatorAddress) external view override returns (bytes32[] memory) {
        return _validatorRequests[validatorAddress];
    }

    /// @notice Length of the agent's validation list. Pair with
    ///         `getAgentValidationsPaginated` to walk it without materializing
    ///         the full array.
    function getAgentValidationCount(uint256 agentId) external view override returns (uint256) {
        return _agentRequests[agentId].length;
    }

    function getAgentValidationsPaginated(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (bytes32[] memory)
    {
        return LibPagination.paginate(_agentRequests[agentId], offset, limit);
    }

    /// @notice Length of the validator's request list. Pair with
    ///         `getValidatorRequestsPaginated`.
    function getValidatorRequestCount(address validatorAddress) external view override returns (uint256) {
        return _validatorRequests[validatorAddress].length;
    }

    function getValidatorRequestsPaginated(address validatorAddress, uint256 offset, uint256 limit)
        external
        view
        override
        returns (bytes32[] memory)
    {
        return LibPagination.paginate(_validatorRequests[validatorAddress], offset, limit);
    }

    function _validatorIncluded(address validator, address[] calldata allowed) internal pure returns (bool) {
        if (allowed.length == 0) return true;
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == validator) return true;
        }
        return false;
    }

    function _summaryPage(
        uint256 agentId,
        address[] calldata validatorAddresses,
        string calldata tag,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint64 count, uint256 totalResponse, uint256 nextOffset) {
        bytes32[] storage requests = _agentRequests[agentId];
        if (offset >= requests.length) return (0, 0, requests.length);

        uint256 end = requests.length - offset > limit ? offset + limit : requests.length;
        bytes32 tagHash = keccak256(bytes(tag));
        bool filterTag = bytes(tag).length != 0;
        for (uint256 i = offset; i < end; i++) {
            Validation storage v = _validations[requests[i]];
            if (!v.hasResponse) continue;
            if (filterTag && keccak256(bytes(v.tag)) != tagHash) continue;
            if (!_validatorIncluded(v.validatorAddress, validatorAddresses)) continue;
            count++;
            totalResponse += v.response;
        }
        nextOffset = end;
    }

    function _validationKey(uint256 agentId, bytes32 requestHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(agentId, requestHash));
    }

    uint256[50] private __gap;
}
