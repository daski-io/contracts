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
///         per validation (the spec allows multiple calls; each overwrites
///         response/responseHash/tag and bumps lastUpdate — the full history
///         is recoverable from events).
///
/// Daski hardening (audit L-2): records are keyed by
/// `validationKey = keccak256(agentId, requestHash)` rather than the raw
/// `requestHash`. validationRequest is auth-gated on `agentId`, so a caller can
/// only create keys within agents they control — this removes the cross-agent
/// "request-hash squatting" griefing vector where anyone could front-run and
/// occupy a global requestHash slot. validationRequest returns the key; it is
/// the handle for validationResponse / reads, and `computeValidationKey`
/// re-derives it off-chain.
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
    }

    IERC721 public identityRegistry;

    // validationKey = keccak256(agentId, requestHash) → record
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

    /// @inheritdoc IValidationRegistry
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

        // Namespace the key by agentId. Because this call is auth-gated on
        // agentId, a caller can only occupy keys within agents they control —
        // so the same requestHash registered for some other agent cannot block
        // this one (audit L-2: cross-agent request-hash squatting).
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
            exists: true
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

        emit ValidationResponse(v.validatorAddress, v.agentId, v.requestHash, response, responseURI, responseHash, tag);
    }

    function getValidationStatus(bytes32 validationKey)
        external
        view
        override
        returns (
            address validatorAddress,
            uint256 agentId,
            bytes32 requestHash,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        Validation storage v = _validations[validationKey];
        require(v.exists, "no such request");
        return (v.validatorAddress, v.agentId, v.requestHash, v.response, v.responseHash, v.tag, v.lastUpdate);
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

    function _validationKey(uint256 agentId, bytes32 requestHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(agentId, requestHash));
    }

    uint256[50] private __gap;
}
