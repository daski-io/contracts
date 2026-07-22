// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC3009} from "../../src/interfaces/IERC3009.sol";

/// @notice Test-only USDC with both EIP-3009 (`transferWithAuthorization`) and
/// EIP-2612 (`permit`) so adapters can exercise the full production signing
/// paths. Domain is name="USDC" version="2" — signers must use the same
/// values when building the typed-data hash.
///
/// NOTE: OZ's ERC20Permit wires EIP-712 for the `permit` path with the token
/// name and version "1". For the EIP-3009 path we want version "2" (parity
/// with production USDC's 3009 domain), so instead of inheriting EIP712 a
/// second time we hand-roll a dedicated 3009 domain separator in the
/// constructor (`_TRANSFER_DOMAIN_SEPARATOR`). The two authorization types use
/// independent type hashes and each carries its own full domain separator, so
/// they co-exist safely as two separate typed-data namespaces.
contract MockUSDC is ERC20, ERC20Permit, IERC3009 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    // Dedicated EIP-712 domain separator for the EIP-3009 authorization
    // type. Distinct from ERC20Permit's separator because we want version
    // "2" to mirror production USDC's EIP-3009 domain (ERC20Permit uses
    // version "1"). Cached at construction.
    bytes32 private immutable _TRANSFER_DOMAIN_SEPARATOR;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    constructor() ERC20("USDC", "USDC") ERC20Permit("USDC") {
        // Belt-and-suspenders: this contract has unrestricted public mint and
        // is testnet-only. Reject deployment to known L1/L2 mainnets to make
        // a misconfigured deploy script fail loudly instead of silently
        // pushing fake-USDC to a chain where users could mistake it for real.
        require(block.chainid != 1, "no mainnet (eth)");
        require(block.chainid != 8453, "no mainnet (base)");
        require(block.chainid != 10, "no mainnet (op)");
        require(block.chainid != 42161, "no mainnet (arb)");
        require(block.chainid != 137, "no mainnet (poly)");

        _TRANSFER_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USDC")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(block.timestamp > validAfter, "auth not yet valid");
        require(block.timestamp < validBefore, "auth expired");
        require(!_authorizationStates[from][nonce], "auth already used");

        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _TRANSFER_DOMAIN_SEPARATOR, structHash));
        require(ECDSA.recover(digest, v, r, s) == from, "invalid signature");

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, value);
    }
}
