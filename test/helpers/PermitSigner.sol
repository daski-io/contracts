// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IPermitAdapter} from "../../src/interfaces/IPermitAdapter.sol";
import {IERC20Permit} from "../../src/interfaces/IERC20Permit.sol";

/// @notice Helper for signing EIP-2612 permits. Domain is extracted from the
/// token's DOMAIN_SEPARATOR view (so tests don't have to duplicate the
/// token's domain name/version — this works for any EIP-2612 token).
library PermitSigner {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function signPermit(
        Vm vm,
        uint256 privateKey,
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (IPermitAdapter.PermitData memory data) {
        uint256 nonce = IERC20Permit(token).nonces(owner);
        bytes32 domainSep = IERC20Permit(token).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        data = IPermitAdapter.PermitData({value: value, deadline: deadline, v: v, r: r, s: s});
    }
}
