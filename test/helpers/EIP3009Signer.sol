// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IX402Adapter} from "../../src/interfaces/IX402Adapter.sol";

/// @notice Helper for signing EIP-3009 TransferWithAuthorization messages
/// in Foundry tests. Mirrors the encoding MockUSDC uses via our own
/// domain separator (name="USDC", version="2", chainId, verifyingContract).
///
/// NOTE: the signed `to` address is whatever the caller passes in. In the
/// current architecture, settling via the X402Adapter requires the signed
/// `to` to be the ROUTER address — funds flow buyer → router directly,
/// with the adapter acting only as a thin routing front-end.
library EIP3009Signer {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function domainSeparator(address token) internal view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes("USDC")), keccak256(bytes("2")), block.chainid, token)
        );
    }

    function signTransfer(
        Vm vm,
        uint256 privateKey,
        address token,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (IX402Adapter.EIP3009Auth memory auth) {
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(token), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        auth = IX402Adapter.EIP3009Auth({
            from: from, validAfter: validAfter, validBefore: validBefore, nonce: nonce, v: v, r: r, s: s
        });
    }
}
