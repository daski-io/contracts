// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OutcomeSplitter} from "./OutcomeSplitter.sol";
import {OutcomeSplitterCreate2} from "./utils/OutcomeSplitterCreate2.sol";
import {OutcomeSplitterValidation} from "./utils/OutcomeSplitterValidation.sol";

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
        bytes32 splitterInitCodeHash = OutcomeSplitterCreate2.initCodeHash(
            canonicalChainId,
            canonicalToken,
            providerPayee,
            daskiCommissionReceiver,
            commissionBps,
            policyVersionHash,
            outcomeIdHash,
            listingCommitmentHash,
            listingEpoch
        );
        address predicted = OutcomeSplitterCreate2.computeAddress(address(this), salt, splitterInitCodeHash);
        OutcomeSplitterValidation.validate(
            canonicalChainId,
            canonicalToken,
            providerPayee,
            daskiCommissionReceiver,
            commissionBps,
            policyVersionHash,
            outcomeIdHash,
            listingCommitmentHash,
            listingEpoch,
            predicted
        );
        return predicted;
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
    ) external pure returns (bytes32) {
        return OutcomeSplitterCreate2.initCodeHash(
            canonicalChainId,
            canonicalToken,
            providerPayee,
            daskiCommissionReceiver,
            commissionBps,
            policyVersionHash,
            outcomeIdHash,
            listingCommitmentHash,
            listingEpoch
        );
    }

    function splitterCreationCodeHash() external pure returns (bytes32) {
        return OutcomeSplitterCreate2.creationCodeHash();
    }
}
