// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitter} from "./OutcomeSplitter.sol";

/// @notice Permissionless deterministic deployer for immutable outcome splitters.
contract OutcomeSplitterFactory {
    event OutcomeSplitterDeployed(
        address indexed splitter,
        bytes32 indexed salt,
        bytes32 indexed outcomeIdHash,
        uint64 listingEpoch,
        bytes32 listingCommitmentHash
    );

    function deploy(
        bytes32 salt,
        uint256 canonicalChainId,
        address canonicalToken,
        address providerPayee,
        address daskiCommissionReceiver,
        uint16 commissionBps,
        bytes32 policyVersionHash,
        bytes32 outcomeIdHash,
        bytes32 listingCommitmentHash,
        uint64 listingEpoch
    ) external returns (address splitter) {
        splitter = address(
            new OutcomeSplitter{salt: salt}(
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
        );
        emit OutcomeSplitterDeployed(splitter, salt, outcomeIdHash, listingEpoch, listingCommitmentHash);
    }

    function computeAddress(
        bytes32 salt,
        uint256 canonicalChainId,
        address canonicalToken,
        address providerPayee,
        address daskiCommissionReceiver,
        uint16 commissionBps,
        bytes32 policyVersionHash,
        bytes32 outcomeIdHash,
        bytes32 listingCommitmentHash,
        uint64 listingEpoch
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
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
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
