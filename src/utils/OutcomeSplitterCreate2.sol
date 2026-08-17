// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitter} from "../OutcomeSplitter.sol";

/// @notice Local CREATE2 derivation helpers for reviewed outcome splitter deployments.
library OutcomeSplitterCreate2 {
    function creationCodeHash() internal pure returns (bytes32) {
        return keccak256(type(OutcomeSplitter).creationCode);
    }

    function initCodeHash(
        uint256 canonicalChainId,
        address canonicalToken,
        address providerPayee,
        address daskiCommissionReceiver,
        uint16 commissionBps,
        bytes32 policyVersionHash,
        bytes32 outcomeIdHash,
        bytes32 listingCommitmentHash,
        uint64 listingEpoch
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(OutcomeSplitter).creationCode,
                abi.encode(
                    canonicalChainId,
                    canonicalToken,
                    providerPayee,
                    daskiCommissionReceiver,
                    commissionBps,
                    policyVersionHash,
                    outcomeIdHash,
                    listingCommitmentHash,
                    listingEpoch
                )
            )
        );
    }

    function computeAddress(address factory, bytes32 salt, bytes32 initCodeHash_) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash_)))));
    }
}
