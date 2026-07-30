// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EIP3009Signer} from "./helpers/EIP3009Signer.sol";

contract X402VectorsTest is Test {
    bytes32 private constant NONCE_DOMAIN = keccak256("DASKI_X402_RECEIVE_V1");
    bytes32 private constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    struct Vector {
        uint256 chainId;
        address token;
        string name;
        string version;
        bytes32 domainSeparator;
        address adapter;
        address router;
        address payer;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        uint256 providerAgentId;
        bytes32 serviceId;
        bytes32 serviceRef;
        bytes32 nonceSalt;
        bytes32 nonce;
        bytes32 structHash;
        bytes32 digest;
        address signer;
        bytes signature;
    }

    function test_reproducesBaseMainnetVector() public view {
        _assertVector(0);
    }

    function test_reproducesBaseSepoliaVector() public view {
        _assertVector(1);
    }

    function _assertVector(uint256 index) private view {
        Vector memory vector = _loadVector(index);
        bytes32 nonce = keccak256(
            abi.encode(
                NONCE_DOMAIN,
                vector.chainId,
                vector.adapter,
                vector.router,
                vector.token,
                vector.payer,
                vector.amount,
                vector.validAfter,
                vector.validBefore,
                vector.providerAgentId,
                vector.serviceId,
                vector.serviceRef,
                vector.nonceSalt
            )
        );
        assertEq(nonce, vector.nonce);

        bytes32 domain = EIP3009Signer.domainSeparator(vector.token, vector.name, vector.version, vector.chainId);
        assertEq(domain, vector.domainSeparator);

        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_TYPEHASH,
                vector.payer,
                vector.adapter,
                vector.amount,
                vector.validAfter,
                vector.validBefore,
                nonce
            )
        );
        assertEq(structHash, vector.structHash);

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        assertEq(digest, vector.digest);
        assertEq(_recover(digest, vector.signature), vector.signer);
    }

    function _loadVector(uint256 index) private view returns (Vector memory vector) {
        string memory json = vm.readFile("test/vectors/daski-x402.json");
        string memory root = string.concat(".vectors[", vm.toString(index), "]");
        vector.chainId = vm.parseJsonUint(json, string.concat(root, ".chainId"));
        vector.token = vm.parseJsonAddress(json, string.concat(root, ".token"));
        vector.name = vm.parseJsonString(json, string.concat(root, ".name"));
        vector.version = vm.parseJsonString(json, string.concat(root, ".version"));
        vector.domainSeparator = vm.parseJsonBytes32(json, string.concat(root, ".domainSeparator"));
        vector.adapter = vm.parseJsonAddress(json, string.concat(root, ".adapter"));
        vector.router = vm.parseJsonAddress(json, string.concat(root, ".router"));
        vector.payer = vm.parseJsonAddress(json, string.concat(root, ".payer"));
        vector.amount = vm.parseUint(vm.parseJsonString(json, string.concat(root, ".amount")));
        vector.validAfter = vm.parseUint(vm.parseJsonString(json, string.concat(root, ".validAfter")));
        vector.validBefore = vm.parseUint(vm.parseJsonString(json, string.concat(root, ".validBefore")));
        vector.providerAgentId = vm.parseUint(vm.parseJsonString(json, string.concat(root, ".providerAgentId")));
        vector.serviceId = vm.parseJsonBytes32(json, string.concat(root, ".serviceId"));
        vector.serviceRef = vm.parseJsonBytes32(json, string.concat(root, ".serviceRef"));
        vector.nonceSalt = vm.parseJsonBytes32(json, string.concat(root, ".nonceSalt"));
        vector.nonce = vm.parseJsonBytes32(json, string.concat(root, ".nonce"));
        vector.structHash = vm.parseJsonBytes32(json, string.concat(root, ".structHash"));
        vector.digest = vm.parseJsonBytes32(json, string.concat(root, ".digest"));
        vector.signer = vm.parseJsonAddress(json, string.concat(root, ".signer"));
        vector.signature = vm.parseJsonBytes(json, string.concat(root, ".signature"));
    }

    function _recover(bytes32 digest, bytes memory signature) private pure returns (address signer) {
        require(signature.length == 65, "invalid vector signature");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        signer = ecrecover(digest, v, r, s);
    }
}
