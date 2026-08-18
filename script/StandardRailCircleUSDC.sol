// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICircleUSDC {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function currency() external view returns (string memory);
    function decimals() external view returns (uint8);
    function version() external view returns (string memory);
    function paused() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
    function pauser() external view returns (address);
    function blacklister() external view returns (address);
    function implementation() external view returns (address);
}

/// @notice Fail-closed identity and liveness checks for the Base Sepolia standard-rail token.
library StandardRailCircleUSDC {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes32 internal constant BASE_SEPOLIA_USDC_PROXY_CODE_HASH =
        0xedc5281a85c0efecd49999a1ef668390c59b88702f2d4a07029d7f5d63059d6c;
    address internal constant BASE_SEPOLIA_USDC_IMPLEMENTATION = 0xd74cc5d436923b8ba2c179b4bCA2841D8A52C5B5;
    bytes32 internal constant BASE_SEPOLIA_USDC_IMPLEMENTATION_CODE_HASH =
        0x1254951e5483b882fd5def9452f58fe786eb3380c0bf9bb2744fa21a0a97a16c;

    struct Snapshot {
        bytes32 proxyCodeHash;
        address implementation;
        bytes32 implementationCodeHash;
        bytes32 nameHash;
        bytes32 symbolHash;
        bytes32 currencyHash;
        uint256 decimals;
        bytes32 versionHash;
        address pauser;
        address blacklister;
        bool paused;
        bool splitterBlacklisted;
        bool providerBlacklisted;
        bool daskiBlacklisted;
    }

    function validate(address token, address splitter, address provider, address daski)
        internal
        view
        returns (address implementation)
    {
        implementation = validateIdentity(
            token,
            BASE_SEPOLIA_CHAIN_ID,
            BASE_SEPOLIA_USDC,
            BASE_SEPOLIA_USDC_PROXY_CODE_HASH,
            BASE_SEPOLIA_USDC_IMPLEMENTATION,
            BASE_SEPOLIA_USDC_IMPLEMENTATION_CODE_HASH
        );
        validateBehavior(token, splitter, provider, daski);
    }

    function validateIdentity(
        address token,
        uint256 expectedChainId,
        address expectedToken,
        bytes32 expectedProxyCodeHash,
        address expectedImplementation,
        bytes32 expectedImplementationCodeHash
    ) internal view returns (address implementation) {
        require(block.chainid == expectedChainId, "standard Testnet rail is Base Sepolia only");
        require(token == expectedToken, "canonical token address mismatch");
        require(token.codehash == expectedProxyCodeHash, "canonical token proxy code hash mismatch");

        implementation = ICircleUSDC(token).implementation();
        require(implementation == expectedImplementation, "canonical token implementation mismatch");
        require(implementation.code.length != 0, "canonical token implementation has no code");
        require(
            implementation.codehash == expectedImplementationCodeHash,
            "canonical token implementation code hash mismatch"
        );
    }

    function validateBehavior(address token, address splitter, address provider, address daski) internal view {
        ICircleUSDC usdc = ICircleUSDC(token);
        require(keccak256(bytes(usdc.name())) == keccak256("USDC"), "canonical token name mismatch");
        require(keccak256(bytes(usdc.symbol())) == keccak256("USDC"), "canonical token symbol mismatch");
        require(keccak256(bytes(usdc.currency())) == keccak256("USD"), "canonical token currency mismatch");
        require(usdc.decimals() == 6, "canonical token decimals mismatch");
        require(keccak256(bytes(usdc.version())) == keccak256("2"), "canonical token version mismatch");
        require(usdc.pauser() != address(0), "canonical token pauser missing");
        require(usdc.blacklister() != address(0), "canonical token blacklister missing");
        require(!usdc.paused(), "canonical token is paused");
        require(!usdc.isBlacklisted(splitter), "splitter is blacklisted");
        require(!usdc.isBlacklisted(provider), "provider is blacklisted");
        require(!usdc.isBlacklisted(daski), "Daski receiver is blacklisted");
    }

    function validateSnapshot(uint256 chainId, address token, Snapshot memory snapshot) internal pure {
        validateSnapshotIdentity(
            chainId,
            token,
            snapshot,
            BASE_SEPOLIA_CHAIN_ID,
            BASE_SEPOLIA_USDC,
            BASE_SEPOLIA_USDC_PROXY_CODE_HASH,
            BASE_SEPOLIA_USDC_IMPLEMENTATION,
            BASE_SEPOLIA_USDC_IMPLEMENTATION_CODE_HASH
        );
        validateSnapshotBehavior(snapshot);
    }

    function validateSnapshotIdentity(
        uint256 chainId,
        address token,
        Snapshot memory snapshot,
        uint256 expectedChainId,
        address expectedToken,
        bytes32 expectedProxyCodeHash,
        address expectedImplementation,
        bytes32 expectedImplementationCodeHash
    ) internal pure {
        require(chainId == expectedChainId, "standard Testnet rail is Base Sepolia only");
        require(token == expectedToken, "canonical token address mismatch");
        require(snapshot.proxyCodeHash == expectedProxyCodeHash, "canonical token proxy code hash mismatch");
        require(snapshot.implementation == expectedImplementation, "canonical token implementation mismatch");
        require(
            snapshot.implementationCodeHash == expectedImplementationCodeHash,
            "canonical token implementation code hash mismatch"
        );
    }

    function validateSnapshotBehavior(Snapshot memory snapshot) internal pure {
        require(snapshot.nameHash == keccak256("USDC"), "canonical token name mismatch");
        require(snapshot.symbolHash == keccak256("USDC"), "canonical token symbol mismatch");
        require(snapshot.currencyHash == keccak256("USD"), "canonical token currency mismatch");
        require(snapshot.decimals == 6, "canonical token decimals mismatch");
        require(snapshot.versionHash == keccak256("2"), "canonical token version mismatch");
        require(snapshot.pauser != address(0), "canonical token pauser missing");
        require(snapshot.blacklister != address(0), "canonical token blacklister missing");
        require(!snapshot.paused, "canonical token is paused");
        require(!snapshot.splitterBlacklisted, "splitter is blacklisted");
        require(!snapshot.providerBlacklisted, "provider is blacklisted");
        require(!snapshot.daskiBlacklisted, "Daski receiver is blacklisted");
    }
}
