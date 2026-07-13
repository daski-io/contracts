// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {AgentIndex} from "../../src/AgentIndex.sol";

/// @notice Builds the EIP-712 RegisterAgent consent signature that
///         AgentIndex.registerWithSig verifies (domain "Daski AgentIndex",
///         version "1", verifyingContract = the AgentIndex proxy).
library AgentIndexSigner {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function registerDigest(AgentIndex index, string memory agentURI, address wallet, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(index.REGISTER_AGENT_TYPEHASH(), keccak256(bytes(agentURI)), wallet, nonce, deadline));
        bytes32 domainSep = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Daski AgentIndex")),
                keccak256(bytes("1")),
                block.chainid,
                address(index)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    /// @dev Signs with the wallet's CURRENT nonce read from the index.
    function signRegister(Vm vm, uint256 walletKey, AgentIndex index, string memory agentURI, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        address wallet = vm.addr(walletKey);
        bytes32 digest = registerDigest(index, agentURI, wallet, index.registrationNonce(wallet), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs with an explicit nonce — for replay/negative tests.
    function signRegisterWithNonce(
        Vm vm,
        uint256 walletKey,
        AgentIndex index,
        string memory agentURI,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = registerDigest(index, agentURI, vm.addr(walletKey), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
