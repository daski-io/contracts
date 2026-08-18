// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployReputationStorage} from "../../script/DeployReputationStorage.s.sol";
import {ReputationStorage} from "../../src/ReputationStorage.sol";

contract ReputationDeploymentDependencyStub {}

contract ReputationProxyRuntimeStub {
    fallback() external {}
}

contract ReputationEASImplementationStub {
    function identityMarker() external pure returns (uint256) {
        return 1;
    }
}

contract ReputationSchemaImplementationStub {
    function identityMarker() external pure returns (uint256) {
        return 2;
    }
}

contract ReputationSafeSingletonStub {
    function versionMarker() external pure returns (uint256) {
        return 141;
    }
}

contract ReputationSafeFallbackHandlerStub {
    function handlerMarker() external pure returns (uint256) {
        return 1;
    }
}

contract ThresholdSafeStub {
    address private _singleton;
    uint256 private _threshold;
    address[] private _owners;
    address[] private _modules;
    address private _guard;
    address private _fallbackHandler;

    address private constant SENTINEL_MODULES = address(0x1);
    bytes32 private constant GUARD_STORAGE_SLOT = keccak256("guard_manager.guard.address");
    bytes32 private constant FALLBACK_HANDLER_STORAGE_SLOT = keccak256("fallback_manager.handler.address");

    constructor(
        address singleton_,
        uint256 threshold_,
        address[] memory owners_,
        address[] memory modules_,
        address guard_,
        address fallbackHandler_
    ) {
        _singleton = singleton_;
        _threshold = threshold_;
        _owners = owners_;
        _modules = modules_;
        _guard = guard_;
        _fallbackHandler = fallbackHandler_;
    }

    function masterCopy() external view returns (address) {
        return _singleton;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory modules, address next)
    {
        require(start == SENTINEL_MODULES, "invalid start");
        uint256 count = _modules.length < pageSize ? _modules.length : pageSize;
        modules = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            modules[i] = _modules[i];
        }
        next = count == _modules.length ? SENTINEL_MODULES : _modules[count];
    }

    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory) {
        require(length == 1, "invalid length");
        if (offset == uint256(GUARD_STORAGE_SLOT)) return abi.encode(_guard);
        if (offset == uint256(FALLBACK_HANDLER_STORAGE_SLOT)) return abi.encode(_fallbackHandler);
        return abi.encode(address(0));
    }

    function setSingleton(address value) external {
        _singleton = value;
    }

    function setThreshold(uint256 value) external {
        _threshold = value;
    }

    function setOwners(address[] calldata value) external {
        _owners = value;
    }

    function setModules(address[] calldata value) external {
        _modules = value;
    }

    function setGuard(address value) external {
        _guard = value;
    }

    function setFallbackHandler(address value) external {
        _fallbackHandler = value;
    }

    function acceptReputationAdmin(ReputationStorage reputation) external {
        reputation.acceptAdmin();
    }

    function activateReputation(ReputationStorage reputation) external {
        reputation.unpauseExternalDependency();
    }
}

contract DeployReputationStorageHarness is DeployReputationStorage {
    address private _reviewedSafeSingleton;
    address private _reviewedSafeHandler;

    function easImplementation() public pure returns (address) {
        return address(0xE451);
    }

    function schemaImplementation() public pure returns (address) {
        return address(0x5C4E);
    }

    function reviewedEASDeployment(uint256 chainId)
        public
        pure
        override
        returns (bytes32, address, bytes32, address, bytes32)
    {
        if (chainId == 8453 || chainId == 84532) {
            return (
                keccak256(type(ReputationProxyRuntimeStub).runtimeCode),
                easImplementation(),
                keccak256(type(ReputationEASImplementationStub).runtimeCode),
                schemaImplementation(),
                keccak256(type(ReputationSchemaImplementationStub).runtimeCode)
            );
        }
        return super.reviewedEASDeployment(chainId);
    }

    function setReviewedSafeContracts(address singleton, address handler) external {
        _reviewedSafeSingleton = singleton;
        _reviewedSafeHandler = handler;
    }

    function reviewedSafeDeployment(uint256 chainId, address singleton)
        public
        view
        override
        returns (bytes32, bytes32, address, bytes32)
    {
        if (singleton == _reviewedSafeSingleton) {
            return (
                keccak256(type(ThresholdSafeStub).runtimeCode),
                keccak256(type(ReputationSafeSingletonStub).runtimeCode),
                _reviewedSafeHandler,
                keccak256(type(ReputationSafeFallbackHandlerStub).runtimeCode)
            );
        }
        return super.reviewedSafeDeployment(chainId, singleton);
    }

    function validateGovernance(DeploymentConfig calldata config) external view {
        _validateGovernance(config);
    }

    function validateEAS(address easAddress, bool allowNonCanonicalEAS) external view returns (address) {
        return address(_validateEAS(easAddress, allowNonCanonicalEAS));
    }

    function requireHandoffReady(
        ReputationStorage reputation,
        DeploymentConfig calldata config,
        bytes32 outcomeSchema,
        bytes32 confirmationSchema
    ) external view {
        _requireHandoffReady(reputation, config, outcomeSchema, confirmationSchema);
    }
}
