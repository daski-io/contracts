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

    bytes32 private constant MODULE_GUARD_STORAGE_SLOT = keccak256("module_manager.module_guard.address");

    struct SafeDeployment {
        bytes32 proxyCodeHash;
        address singleton;
        bytes32 singletonCodeHash;
        address fallbackHandler;
        bytes32 fallbackHandlerCodeHash;
    }

    // Canonical identities and artifact provenance: docs/safe-deployments.md.
    bytes32 private constant SAFE_141_PROXY_HASH = 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    bytes32 private constant SAFE_150_PROXY_HASH = 0x4e381985ca68b3e5d27b4425fa581c19cf33146d3f887a3cfca96f55528ea46f;

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
    error SafeFallbackHandlerCodeHashMismatch(bytes32 actual, bytes32 expected);
    error InvalidSafeModuleGuard(address actual);

    /// @dev Select an exact reviewed deployment by proxy bytecode, never by a reported VERSION string.
    ///      Each proxy version is paired with its reviewed singleton and handler.
    function reviewedSafeDeployment(uint256 chainId, bytes32 proxyCodeHash)
        public
        view
        virtual
        returns (SafeDeployment memory)
    {
        if (chainId != BASE_CHAIN_ID && chainId != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedSafeChain(chainId);
        }
        if (proxyCodeHash == SAFE_150_PROXY_HASH) {
            return SafeDeployment({
                proxyCodeHash: SAFE_150_PROXY_HASH,
                singleton: 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e,
                singletonCodeHash: 0x180193227186ccb85316c94db1f0d156ed932b14712cfaac78901899178572dc,
                fallbackHandler: 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4,
                fallbackHandlerCodeHash: 0x3c6a85bcf7b563daa624b884b4e9a1b9fa5371edde7be945d998071a48f28bbc
            });
        }
        // Unknown proxy runtimes fail the comparison in _validateSafe.
        return SafeDeployment({
            proxyCodeHash: SAFE_141_PROXY_HASH,
            singleton: 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762,
            singletonCodeHash: 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff,
            fallbackHandler: 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99,
            fallbackHandlerCodeHash: 0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9
        });
    }

    function _validateSafe(address safe) internal view {
        SafeDeployment memory reviewed = reviewedSafeDeployment(block.chainid, safe.codehash);
        if (safe.code.length == 0) revert FinalAdminMustBeReviewedSafe(safe);
        if (safe.codehash != reviewed.proxyCodeHash) {
            revert SafeProxyCodeHashMismatch(safe.codehash, reviewed.proxyCodeHash);
        }

        address singleton;
        try IReviewedSafeProxy(safe).masterCopy() returns (address value) {
            singleton = value;
        } catch {
            revert FinalAdminMustBeReviewedSafe(safe);
        }
        if (singleton != reviewed.singleton) revert SafeSingletonMismatch(singleton, reviewed.singleton);
        if (singleton.codehash != reviewed.singletonCodeHash) {
            revert SafeSingletonCodeHashMismatch(singleton.codehash, reviewed.singletonCodeHash);
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
        address moduleGuard = _storageAddress(safe, MODULE_GUARD_STORAGE_SLOT);
        if (moduleGuard != address(0)) revert InvalidSafeModuleGuard(moduleGuard);
        address handler = _storageAddress(safe, FALLBACK_HANDLER_STORAGE_SLOT);
        if (handler != reviewed.fallbackHandler) revert InvalidSafeFallbackHandler(handler);
        if (reviewed.fallbackHandler.code.length == 0) revert SafeFallbackHandlerHasNoCode(reviewed.fallbackHandler);
        if (reviewed.fallbackHandler.codehash != reviewed.fallbackHandlerCodeHash) {
            revert SafeFallbackHandlerCodeHashMismatch(
                reviewed.fallbackHandler.codehash, reviewed.fallbackHandlerCodeHash
            );
        }
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
