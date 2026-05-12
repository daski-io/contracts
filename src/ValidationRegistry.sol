// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ERC-8004 Validation Registry
// Pinned to draft spec commit 503591a6e80e6e1affdd6403341e25269141f046.
// Source: https://github.com/ethereum/ERCs/blob/503591a6/ERCS/erc-8004.md

import {IValidationRegistry} from "./interfaces/IValidationRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Admin2StepUpgradeable} from "./utils/Admin2StepUpgradeable.sol";
import {LibAgentAuth} from "./utils/LibAgentAuth.sol";
import {LibPagination} from "./utils/LibPagination.sol";

/// @notice Minimal ERC-8004 Validation Registry. Stores the latest response
///         per requestHash (the spec allows multiple calls; each overwrites
///         response/responseHash/tag and bumps lastUpdate — the full history
///         is recoverable from events).
contract ValidationRegistry is Admin2StepUpgradeable, IValidationRegistry {
    struct Validation {
        address validatorAddress;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
        bool exists;
    }

    IERC721 public identityRegistry;

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
            response: 0,
            responseHash: bytes32(0),
            tag: "",
            lastUpdate: block.timestamp,
            exists: true
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

        emit ValidationResponse(v.validatorAddress, v.agentId, requestHash, response, responseURI, responseHash, tag);
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

    function getAgentValidations(uint256 agentId) external view override returns (bytes32[] memory) {
        return _agentRequests[agentId];
    }

    function getValidatorRequests(address validatorAddress) external view override returns (bytes32[] memory) {
        return _validatorRequests[validatorAddress];
    }

    /// @notice Length of the agent's validation-request list. Pair with
    ///         `getAgentValidationsPaginated` to walk the list without
    ///         materializing the full array.
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

    uint256[50] private __gap;
}
