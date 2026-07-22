// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";

contract MockCanonicalIdentityRegistryTest is Test {
    MockCanonicalIdentityRegistry identity;
    uint256 constant WALLET_KEY = 0xA11CE;
    address owner = makeAddr("owner");
    address wallet;
    uint256 agentId;

    function setUp() public {
        identity = new MockCanonicalIdentityRegistry();
        wallet = vm.addr(WALLET_KEY);
        vm.prank(owner);
        agentId = identity.register();
    }

    function test_setAgentWalletRejectsDeadlineBeyondFiveMinutes() public {
        uint256 deadline = block.timestamp + 5 minutes + 1;
        bytes memory signature = _sign(agentId, wallet, owner, deadline);

        vm.prank(owner);
        vm.expectRevert("deadline too far");
        identity.setAgentWallet(agentId, wallet, deadline, signature);
    }

    function test_setAgentWalletSignatureIsBoundToCurrentOwner() public {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory staleSignature = _sign(agentId, wallet, owner, deadline);
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        identity.transferFrom(owner, newOwner, agentId);

        vm.prank(newOwner);
        vm.expectRevert("invalid wallet signature");
        identity.setAgentWallet(agentId, wallet, deadline, staleSignature);
    }

    function _sign(uint256 id, address newWallet, address currentOwner, uint256 deadline)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 structHash =
            keccak256(abi.encode(identity.SET_AGENT_WALLET_TYPEHASH(), id, newWallet, currentOwner, deadline));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ERC8004IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(identity)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WALLET_KEY, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
