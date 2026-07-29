// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
    function nonce() external view returns (uint256);
    function masterCopy() external view returns (address);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface IMultiSend {
    function multiSend(bytes memory transactions) external payable;
}

/// @notice Canonical Safe v1.4.1 bindings and calldata builders for the
///         governance Safe used as ADMIN_ADDRESS. Addresses are the
///         deterministic cross-chain deployments and are additionally pinned
///         by runtime codehash (verified identical on Base mainnet and Base
///         Sepolia) so a compromised RPC cannot substitute look-alikes.
library SafeDeployment {
    struct Profile {
        address[] owners;
        uint256 threshold;
        address[] modules;
        address guard;
        address fallbackHandler;
        bool releaseCandidate;
    }

    uint256 internal constant BASE_MAINNET = 8453;

    /// SafeProxy v1.4.1.
    bytes32 internal constant SAFE_PROXY_CODEHASH = 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;

    /// SafeProxyFactory v1.4.1.
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    bytes32 internal constant SAFE_PROXY_FACTORY_CODEHASH =
        0x50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317;

    /// SafeL2 v1.4.1 singleton (events variant, correct for L2 chains).
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 internal constant SAFE_L2_SINGLETON_CODEHASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;

    /// CompatibilityFallbackHandler v1.4.1.
    address internal constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    bytes32 internal constant COMPATIBILITY_FALLBACK_HANDLER_CODEHASH =
        0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9;

    /// MultiSendCallOnly v1.4.1 — delegatecall target that refuses nested
    /// delegatecalls, so a batch can never touch Safe storage.
    address internal constant MULTI_SEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    bytes32 internal constant MULTI_SEND_CALL_ONLY_CODEHASH =
        0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;

    uint8 internal constant OPERATION_CALL = 0;
    uint8 internal constant OPERATION_DELEGATECALL = 1;
    address internal constant SENTINEL_MODULES = address(0x1);
    uint256 internal constant GUARD_STORAGE_SLOT = uint256(keccak256("guard_manager.guard.address"));
    uint256 internal constant FALLBACK_HANDLER_STORAGE_SLOT = uint256(keccak256("fallback_manager.handler.address"));

    function validateCanonicalDeployment() internal view {
        _requireCodehash(SAFE_PROXY_FACTORY, SAFE_PROXY_FACTORY_CODEHASH, "SafeProxyFactory");
        _requireCodehash(SAFE_L2_SINGLETON, SAFE_L2_SINGLETON_CODEHASH, "SafeL2 singleton");
        _requireCodehash(COMPATIBILITY_FALLBACK_HANDLER, COMPATIBILITY_FALLBACK_HANDLER_CODEHASH, "fallback handler");
        _requireCodehash(MULTI_SEND_CALL_ONLY, MULTI_SEND_CALL_ONLY_CODEHASH, "MultiSendCallOnly");
    }

    /// @notice Validate the complete governance identity and configuration.
    function validateSafeProfile(address safe, Profile memory profile) internal view {
        require(safe.codehash == SAFE_PROXY_CODEHASH, "governance is not canonical SafeProxy");
        ISafe target = ISafe(safe);
        require(target.masterCopy() == SAFE_L2_SINGLETON, "wrong Safe singleton");
        _validateOwners(target, profile.owners);
        require(target.getThreshold() == profile.threshold, "wrong Safe threshold");
        _validateModules(target, profile.modules);
        require(_storageAddress(target, GUARD_STORAGE_SLOT) == profile.guard, "wrong Safe guard");
        require(profile.fallbackHandler == COMPATIBILITY_FALLBACK_HANDLER, "manifest fallback handler is not canonical");
        require(
            _storageAddress(target, FALLBACK_HANDLER_STORAGE_SLOT) == profile.fallbackHandler,
            "wrong Safe fallback handler"
        );

        if (block.chainid == BASE_MAINNET || profile.releaseCandidate) {
            require(
                profile.owners.length >= 2 && profile.threshold >= 2,
                "release governance requires >=2 owners and threshold >=2"
            );
        }
        _requireCodehash(SAFE_L2_SINGLETON, SAFE_L2_SINGLETON_CODEHASH, "SafeL2 singleton");
        _requireCodehash(COMPATIBILITY_FALLBACK_HANDLER, COMPATIBILITY_FALLBACK_HANDLER_CODEHASH, "fallback handler");
    }

    /// @notice Safe.setup calldata for a fresh Safe: no module setup call, no
    ///         payment, canonical fallback handler.
    function setupInitializer(address[] memory owners, uint256 threshold) internal pure returns (bytes memory) {
        require(owners.length > 0, "owners required");
        require(threshold >= 1 && threshold <= owners.length, "invalid threshold");
        for (uint256 i = 0; i < owners.length; i++) {
            require(owners[i] != address(0), "zero owner");
            for (uint256 j = i + 1; j < owners.length; j++) {
                require(owners[i] != owners[j], "duplicate owner");
            }
        }
        return abi.encodeCall(
            ISafe.setup,
            (owners, threshold, address(0), "", COMPATIBILITY_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
    }

    /// @notice Pre-validated signature accepted by checkSignatures when the
    ///         validating owner IS msg.sender of execTransaction:
    ///         r = owner address, s unused, v = 1.
    function prevalidatedSignature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    /// @notice Pack (targets, calls) into a MultiSendCallOnly `transactions`
    ///         blob: {operation:uint8 = CALL, to:address, value:uint256 = 0,
    ///         dataLength:uint256, data} per entry.
    function packMultiSend(address[] memory targets, bytes[] memory calls) internal pure returns (bytes memory packed) {
        require(targets.length == calls.length, "length mismatch");
        require(targets.length > 0, "empty batch");
        for (uint256 i = 0; i < targets.length; i++) {
            packed =
                abi.encodePacked(packed, OPERATION_CALL, targets[i], uint256(0), uint256(calls[i].length), calls[i]);
        }
    }

    /// @notice Execute one batch through the Safe as a single delegatecall to
    ///         MultiSendCallOnly. The broadcasting EOA must be an owner of a
    ///         1-of-1 Safe; anything stronger is a manual multisig ceremony.
    function execMultiSendBatch(address safe, address sender, address[] memory targets, bytes[] memory calls) internal {
        ISafe target = ISafe(safe);
        require(target.isOwner(sender), "sender is not a Safe owner");
        require(target.getThreshold() == 1, "threshold > 1: execute the logged batch via the Safe app");
        bytes memory data = abi.encodeCall(IMultiSend.multiSend, (packMultiSend(targets, calls)));
        bool success = target.execTransaction(
            MULTI_SEND_CALL_ONLY,
            0,
            data,
            OPERATION_DELEGATECALL,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            prevalidatedSignature(sender)
        );
        require(success, "Safe batch execution failed");
    }

    function _requireCodehash(address target, bytes32 expected, string memory name) private view {
        require(target.code.length > 0, string.concat(name, " has no code on this chain"));
        require(target.codehash == expected, string.concat(name, " codehash mismatch"));
    }

    function _validateOwners(ISafe safe, address[] memory expected) private view {
        address[] memory live = safe.getOwners();
        require(live.length == expected.length, "wrong Safe owner count");
        for (uint256 i = 0; i < expected.length; i++) {
            require(expected[i] != address(0), "zero expected Safe owner");
            require(safe.isOwner(expected[i]), "expected Safe owner missing");
            for (uint256 j = i + 1; j < expected.length; j++) {
                require(expected[i] != expected[j], "duplicate expected Safe owner");
            }
        }
    }

    function _validateModules(ISafe safe, address[] memory expected) private view {
        (address[] memory live, address next) = safe.getModulesPaginated(SENTINEL_MODULES, expected.length + 1);
        require(next == SENTINEL_MODULES, "unexpected additional Safe modules");
        require(live.length == expected.length, "wrong Safe module count");
        for (uint256 i = 0; i < expected.length; i++) {
            require(expected[i] != address(0) && expected[i] != SENTINEL_MODULES, "invalid expected Safe module");
            bool found;
            for (uint256 j = 0; j < live.length; j++) {
                if (live[j] == expected[i]) found = true;
            }
            require(found, "expected Safe module missing");
        }
    }

    function _storageAddress(ISafe safe, uint256 slot) private view returns (address value) {
        bytes memory stored = safe.getStorageAt(slot, 1);
        require(stored.length == 32, "invalid Safe storage response");
        assembly ("memory-safe") {
            value := mload(add(stored, 0x20))
        }
    }
}
