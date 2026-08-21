// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IReviewedSafeProxy {
    function masterCopy() external view returns (address);
}

interface IReviewedSafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory modules, address next);
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);
}

/// @notice Checks the minimum Safe controls required before transferring administration.
abstract contract ReputationSafeValidation {
    uint256 private constant BASE_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant SENTINEL_MODULES = address(0x1);
    bytes32 private constant GUARD_STORAGE_SLOT = keccak256("guard_manager.guard.address");
    bytes32 private constant FALLBACK_HANDLER_STORAGE_SLOT = keccak256("fallback_manager.handler.address");

    // Canonical Safe v1.4.1 identities from safe-global/safe-deployments.
    bytes32 private constant SAFE_PROXY_RUNTIME_CODE_HASH =
        0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    address private constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 private constant SAFE_L2_SINGLETON_RUNTIME_CODE_HASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    address private constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    error UnsupportedSafeChain(uint256 chainId);
    error FinalAdminMustBeReviewedSafe(address candidate);
    error SafeProxyCodeHashMismatch(bytes32 actual, bytes32 expected);
    error SafeSingletonMismatch(address actual, address expected);
    error SafeSingletonCodeHashMismatch(bytes32 actual, bytes32 expected);
    error InvalidSafeOwners();
    error InvalidSafeThreshold(uint256 actual, uint256 ownerCount);
    error InvalidSafeModules();
    error InvalidSafeGuard(address actual);
    error InvalidSafeFallbackHandler(address actual);
    error SafeFallbackHandlerHasNoCode(address handler);

    function reviewedSafeDeployment(uint256 chainId)
        public
        view
        virtual
        returns (bytes32 proxyCodeHash, address singleton, bytes32 singletonCodeHash, address fallbackHandler)
    {
        if (chainId != BASE_CHAIN_ID && chainId != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedSafeChain(chainId);
        }
        return (
            SAFE_PROXY_RUNTIME_CODE_HASH,
            SAFE_L2_SINGLETON,
            SAFE_L2_SINGLETON_RUNTIME_CODE_HASH,
            COMPATIBILITY_FALLBACK_HANDLER
        );
    }

    function _validateSafe(address safe) internal view {
        (bytes32 proxyHash, address reviewedSingleton, bytes32 singletonHash, address reviewedHandler) =
            reviewedSafeDeployment(block.chainid);
        if (safe.code.length == 0) revert FinalAdminMustBeReviewedSafe(safe);
        if (safe.codehash != proxyHash) revert SafeProxyCodeHashMismatch(safe.codehash, proxyHash);

        address singleton;
        try IReviewedSafeProxy(safe).masterCopy() returns (address value) {
            singleton = value;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (singleton != reviewedSingleton) revert SafeSingletonMismatch(singleton, reviewedSingleton);
        if (singleton.codehash != singletonHash) {
            revert SafeSingletonCodeHashMismatch(singleton.codehash, singletonHash);
        }

        address[] memory owners;
        try IReviewedSafe(safe).getOwners() returns (address[] memory values) {
            owners = values;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (owners.length < 2) revert InvalidSafeOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == address(0)) revert InvalidSafeOwners();
            for (uint256 j = i + 1; j < owners.length; j++) {
                if (owners[i] == owners[j]) revert InvalidSafeOwners();
            }
        }

        uint256 threshold;
        try IReviewedSafe(safe).getThreshold() returns (uint256 value) {
            threshold = value;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (threshold < 2 || threshold > owners.length) {
            revert InvalidSafeThreshold(threshold, owners.length);
        }

        address[] memory modules;
        address next;
        try IReviewedSafe(safe).getModulesPaginated(SENTINEL_MODULES, 1) returns (
            address[] memory values, address nextModule
        ) {
            modules = values;
            next = nextModule;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (modules.length != 0 || next != SENTINEL_MODULES) revert InvalidSafeModules();

        address guard = _storageAddress(safe, GUARD_STORAGE_SLOT);
        if (guard != address(0)) revert InvalidSafeGuard(guard);
        address handler = _storageAddress(safe, FALLBACK_HANDLER_STORAGE_SLOT);
        if (handler != reviewedHandler) revert InvalidSafeFallbackHandler(handler);
        if (reviewedHandler.code.length == 0) revert SafeFallbackHandlerHasNoCode(reviewedHandler);
    }

    function _storageAddress(address safe, bytes32 slot) private view returns (address value) {
        bytes memory word;
        try IReviewedSafe(safe).getStorageAt(uint256(slot), 1) returns (bytes memory result) {
            word = result;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (word.length != 32) revert FinalAdminMustBeReviewedSafe(safe);
        value = abi.decode(word, (address));
    }
}
