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

/// @notice Validates the exact Safe v1.4.1 identity and reviewed governance profile.
abstract contract ReputationSafeValidation {
    struct SafeProfile {
        address singleton;
        address[] owners;
        uint256 threshold;
        address[] modules;
        address guard;
        address fallbackHandler;
    }

    uint256 private constant BASE_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant SENTINEL_MODULES = address(0x1);
    bytes32 private constant GUARD_STORAGE_SLOT = keccak256("guard_manager.guard.address");
    bytes32 private constant FALLBACK_HANDLER_STORAGE_SLOT = keccak256("fallback_manager.handler.address");

    // Canonical Safe v1.4.1 identities from safe-global/safe-deployments.
    // https://github.com/safe-global/safe-deployments/tree/main/src/assets/v1.4.1
    bytes32 private constant SAFE_PROXY_RUNTIME_CODE_HASH =
        0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    address private constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    bytes32 private constant SAFE_SINGLETON_RUNTIME_CODE_HASH =
        0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4;
    address private constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 private constant SAFE_L2_SINGLETON_RUNTIME_CODE_HASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    address private constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    bytes32 private constant COMPATIBILITY_FALLBACK_HANDLER_RUNTIME_CODE_HASH =
        0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9;

    error UnsupportedSafeChain(uint256 chainId);
    error UnsupportedSafeSingleton(address singleton);
    error FinalAdminMustBeReviewedSafe(address candidate);
    error SafeProxyCodeHashMismatch(bytes32 actual, bytes32 expected);
    error SafeSingletonMismatch(address actual, address expected);
    error SafeSingletonCodeHashMismatch(bytes32 actual, bytes32 expected);
    error SafeFallbackHandlerCodeHashMismatch(bytes32 actual, bytes32 expected);
    error InvalidSafeOwners();
    error InvalidExpectedSafeThreshold(uint256 threshold, uint256 ownerCount);
    error InvalidSafeThreshold(uint256 actual, uint256 expected);
    error InvalidSafeModules();
    error InvalidSafeGuard(address actual, address expected);
    error InvalidSafeFallbackHandler(address actual, address expected);
    error DuplicateSafeAddress(address account);

    function reviewedSafeDeployment(uint256 chainId, address singleton)
        public
        view
        virtual
        returns (
            bytes32 proxyCodeHash,
            bytes32 singletonCodeHash,
            address fallbackHandler,
            bytes32 fallbackHandlerCodeHash
        )
    {
        if (chainId != BASE_CHAIN_ID && chainId != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedSafeChain(chainId);
        }
        if (singleton == SAFE_SINGLETON) singletonCodeHash = SAFE_SINGLETON_RUNTIME_CODE_HASH;
        else if (singleton == SAFE_L2_SINGLETON) singletonCodeHash = SAFE_L2_SINGLETON_RUNTIME_CODE_HASH;
        else revert UnsupportedSafeSingleton(singleton);
        return (
            SAFE_PROXY_RUNTIME_CODE_HASH,
            singletonCodeHash,
            COMPATIBILITY_FALLBACK_HANDLER,
            COMPATIBILITY_FALLBACK_HANDLER_RUNTIME_CODE_HASH
        );
    }

    function _validateSafeProfile(address safe, SafeProfile memory expected) internal view {
        (bytes32 proxyHash, bytes32 singletonHash, address reviewedHandler, bytes32 handlerHash) =
            reviewedSafeDeployment(block.chainid, expected.singleton);
        if (safe.code.length == 0) revert FinalAdminMustBeReviewedSafe(safe);
        if (safe.codehash != proxyHash) revert SafeProxyCodeHashMismatch(safe.codehash, proxyHash);

        address singleton;
        try IReviewedSafeProxy(safe).masterCopy() returns (address value) {
            singleton = value;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (singleton != expected.singleton) revert SafeSingletonMismatch(singleton, expected.singleton);
        if (singleton.codehash != singletonHash) {
            revert SafeSingletonCodeHashMismatch(singleton.codehash, singletonHash);
        }
        if (expected.fallbackHandler != reviewedHandler) {
            revert InvalidSafeFallbackHandler(expected.fallbackHandler, reviewedHandler);
        }
        if (reviewedHandler.codehash != handlerHash) {
            revert SafeFallbackHandlerCodeHashMismatch(reviewedHandler.codehash, handlerHash);
        }

        _validateOwnersAndThreshold(safe, expected);
        _validateModules(safe, expected.modules);
        address actualGuard = _storageAddress(safe, GUARD_STORAGE_SLOT);
        if (actualGuard != expected.guard) revert InvalidSafeGuard(actualGuard, expected.guard);
        address actualHandler = _storageAddress(safe, FALLBACK_HANDLER_STORAGE_SLOT);
        if (actualHandler != expected.fallbackHandler) {
            revert InvalidSafeFallbackHandler(actualHandler, expected.fallbackHandler);
        }
    }

    function _validateOwnersAndThreshold(address safe, SafeProfile memory expected) private view {
        _requireUnique(expected.owners, false);
        if (expected.owners.length < 2 || expected.threshold < 2 || expected.threshold > expected.owners.length) {
            revert InvalidExpectedSafeThreshold(expected.threshold, expected.owners.length);
        }
        address[] memory actualOwners;
        uint256 actualThreshold;
        try IReviewedSafe(safe).getOwners() returns (address[] memory value) {
            actualOwners = value;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        try IReviewedSafe(safe).getThreshold() returns (uint256 value) {
            actualThreshold = value;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        _requireUnique(actualOwners, false);
        if (!_sameSet(actualOwners, expected.owners)) revert InvalidSafeOwners();
        if (actualThreshold != expected.threshold) revert InvalidSafeThreshold(actualThreshold, expected.threshold);
    }

    function _validateModules(address safe, address[] memory expected) private view {
        _requireUnique(expected, true);
        address[] memory actual;
        address next;
        try IReviewedSafe(safe).getModulesPaginated(SENTINEL_MODULES, expected.length + 1) returns (
            address[] memory modules, address nextModule
        ) {
            actual = modules;
            next = nextModule;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        _requireUnique(actual, true);
        if (next != SENTINEL_MODULES || !_sameSet(actual, expected)) revert InvalidSafeModules();
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

    function _requireUnique(address[] memory values, bool modules) private pure {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == address(0) || (modules && values[i] == SENTINEL_MODULES)) {
                revert DuplicateSafeAddress(values[i]);
            }
            for (uint256 j = i + 1; j < values.length; j++) {
                if (values[i] == values[j]) revert DuplicateSafeAddress(values[i]);
            }
        }
    }

    function _sameSet(address[] memory left, address[] memory right) private pure returns (bool) {
        if (left.length != right.length) return false;
        for (uint256 i = 0; i < left.length; i++) {
            bool found;
            for (uint256 j = 0; j < right.length; j++) {
                if (left[i] == right[j]) found = true;
            }
            if (!found) return false;
        }
        return true;
    }
}
