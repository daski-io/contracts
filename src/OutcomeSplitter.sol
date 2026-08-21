// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOutcomeSplitter} from "./interfaces/IOutcomeSplitter.sol";
import {OutcomeSplitterValidation} from "./utils/OutcomeSplitterValidation.sol";

/// @notice Immutable, permissionless splitter for one Daski outcome epoch.
contract OutcomeSplitter is IOutcomeSplitter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public immutable override canonicalChainId;
    address public immutable override canonicalToken;
    address public immutable override providerPayee;
    address public immutable override daskiCommissionReceiver;
    uint16 public immutable override commissionBps;
    bytes32 public immutable override policyVersionHash;
    bytes32 public immutable override outcomeIdHash;
    bytes32 public immutable override listingCommitmentHash;
    uint64 public immutable override listingEpoch;
    uint64 public override releaseSequence;

    error InvalidChain();
    error InvalidToken();
    error InvalidRecipient();
    error InvalidCommission();
    error InvalidListing();
    error BalanceBelowMinimum(uint256 balance, uint256 minimum);
    error UnexpectedTokenDelta();
    error NativeCurrencyRejected();

    constructor(
        uint256 canonicalChainId_,
        address canonicalToken_,
        address providerPayee_,
        address daskiCommissionReceiver_,
        uint16 commissionBps_,
        bytes32 policyVersionHash_,
        bytes32 outcomeIdHash_,
        bytes32 listingCommitmentHash_,
        uint64 listingEpoch_
    ) {
        OutcomeSplitterValidation.validate(
            canonicalChainId_,
            canonicalToken_,
            providerPayee_,
            daskiCommissionReceiver_,
            commissionBps_,
            policyVersionHash_,
            outcomeIdHash_,
            listingCommitmentHash_,
            listingEpoch_,
            address(this)
        );

        canonicalChainId = canonicalChainId_;
        canonicalToken = canonicalToken_;
        providerPayee = providerPayee_;
        daskiCommissionReceiver = daskiCommissionReceiver_;
        commissionBps = commissionBps_;
        policyVersionHash = policyVersionHash_;
        outcomeIdHash = outcomeIdHash_;
        listingCommitmentHash = listingCommitmentHash_;
        listingEpoch = listingEpoch_;
    }

    function minimumReleasableBalance() public view override returns (uint256) {
        return (BPS_DENOMINATOR + commissionBps - 1) / commissionBps;
    }

    function releaseAll() external override nonReentrant returns (uint256 grossAmount) {
        IERC20 token = IERC20(canonicalToken);
        grossAmount = token.balanceOf(address(this));
        uint256 minimum = minimumReleasableBalance();
        if (grossAmount < minimum) revert BalanceBelowMinimum(grossAmount, minimum);

        uint256 commission = Math.mulDiv(grossAmount, commissionBps, BPS_DENOMINATOR);
        uint256 providerNet = grossAmount - commission;
        if (commission == 0 || providerNet == 0) revert BalanceBelowMinimum(grossAmount, minimum);

        uint256 providerBefore = token.balanceOf(providerPayee);
        token.safeTransfer(providerPayee, providerNet);
        if (
            token.balanceOf(providerPayee) != providerBefore + providerNet
                || token.balanceOf(address(this)) != grossAmount - providerNet
        ) revert UnexpectedTokenDelta();

        uint256 daskiBefore = token.balanceOf(daskiCommissionReceiver);
        token.safeTransfer(daskiCommissionReceiver, commission);
        if (token.balanceOf(daskiCommissionReceiver) != daskiBefore + commission || token.balanceOf(address(this)) != 0)
        {
            revert UnexpectedTokenDelta();
        }

        uint64 sequence = ++releaseSequence;
        emit Released(
            outcomeIdHash,
            listingEpoch,
            sequence,
            policyVersionHash,
            listingCommitmentHash,
            grossAmount,
            providerNet,
            commission
        );
    }

    receive() external payable {
        revert NativeCurrencyRejected();
    }

    fallback() external payable {
        revert NativeCurrencyRejected();
    }
}
