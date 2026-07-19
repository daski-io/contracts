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
///         is recoverable from events).
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

    // ERC-8004 uses requestHash as the global validation handle.
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

    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external override {
        // Spec: MUST be called by owner or operator of agentId.
        LibAgentAuth.requireAgentAuth(identityRegistry, agentId, msg.sender);
        require(validatorAddress != address(0), "zero validator");

        require(!_validations[requestHash].exists, "request exists");

        _validations[requestHash] = Validation({
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

        _agentRequests[agentId].push(requestHash);
        _validatorRequests[validatorAddress].push(requestHash);

        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external override {
        Validation storage v = _validations[requestHash];
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

    function getValidationStatus(bytes32 requestHash)
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
        Validation storage v = _validations[requestHash];
        require(v.exists, "no such request");
        return (v.validatorAddress, v.agentId, v.response, v.responseHash, v.tag, v.lastUpdate);
    }

    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        override
        returns (uint64 count, uint8 averageResponse)
    {
        bytes32 tagHash = keccak256(bytes(tag));
        bool filterTag = bytes(tag).length != 0;
        uint256 total;
        bytes32[] storage requests = _agentRequests[agentId];

        for (uint256 i = 0; i < requests.length; i++) {
            Validation storage v = _validations[requests[i]];
            if (!v.hasResponse) continue;
            if (filterTag && keccak256(bytes(v.tag)) != tagHash) continue;
            if (!_validatorIncluded(v.validatorAddress, validatorAddresses)) continue;
            count++;
            total += v.response;
        }

        if (count != 0) {
            averageResponse = SafeCast.toUint8(total / count);
        }
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

    uint256[50] private __gap;
}
