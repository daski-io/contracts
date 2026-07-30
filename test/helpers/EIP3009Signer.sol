// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IX402Adapter} from "../../src/interfaces/IX402Adapter.sol";

/// @notice EIP-3009 typed-data signing helpers for Foundry tests.
library EIP3009Signer {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function domainSeparator(address token, string memory name, string memory version, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, token)
        );
    }

    function signTransfer(
        Vm vm,
        uint256 privateKey,
        address token,
        string memory name,
        string memory version,
        uint256 chainId,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (IX402Adapter.EIP3009Auth memory auth) {
        auth = _sign(
            vm,
            privateKey,
            token,
            name,
            version,
            chainId,
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce
        );
    }

    function signReceive(
        Vm vm,
        uint256 privateKey,
        address token,
        string memory name,
        string memory version,
        uint256 chainId,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (IX402Adapter.EIP3009Auth memory auth) {
        auth = _sign(
            vm,
            privateKey,
            token,
            name,
            version,
            chainId,
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce
        );
    }

    function _sign(
        Vm vm,
        uint256 privateKey,
        address token,
        string memory name,
        string memory version,
        uint256 chainId,
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) private view returns (IX402Adapter.EIP3009Auth memory auth) {
        bytes32 structHash = keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator(token, name, version, chainId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        auth = IX402Adapter.EIP3009Auth({
            from: from,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: abi.encodePacked(r, s, v)
        });
    }
}
