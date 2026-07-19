// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {ReputationAdmin} from "./ReputationAdmin.sol";

/// @notice Payment/refund accounting and aggregate reputation views.
abstract contract ReputationAccounting is ReputationAdmin {
    function recordPayment(uint256 paymentId) external onlyPaymentRouter {
        require(_records[paymentId].paymentId == 0, "payment already recorded");
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);

        _records[paymentId] = ReputationRecord({
            paymentId: paymentId,
            providerAgentId: payment.providerAgentId,
            buyerAgentId: payment.buyerAgentId,
            serviceId: payment.serviceId,
            outcome: TransactionOutcome.Completed,
            confirmation: BuyerConfirmation.Pending,
            outcomeAttestationDelay: 0,
            outcomeTimestamp: 0,
            confirmationTimestamp: 0,
            outcomeRecorded: false,
            currentConfirmationUid: bytes32(0),
            reputationEligible: payment.reputationEligible
        });
        recordIds.push(paymentId);
        if (payment.reputationEligible) {
            providerTransactionCount[payment.providerAgentId]++;
            serviceTransactionCount[payment.serviceId]++;
            buyerTransactionCount[payment.buyerAgentId]++;
        }
        emit PaymentRecorded(
            paymentId, payment.providerAgentId, payment.buyerAgentId, payment.serviceId, payment.reputationEligible
        );
    }

    function recordRefund(uint256 paymentId, uint256 amountToBuyer) external onlyPaymentRouter {
        ReputationRecord storage record = _records[paymentId];
        require(record.paymentId != 0, "payment not recorded");
        uint256 cumulative = refundedAmount[paymentId] + amountToBuyer;
        refundedAmount[paymentId] = cumulative;
        refundedAmountByService[record.serviceId] += amountToBuyer;
        emit ReputationRefunded(paymentId, record.serviceId, amountToBuyer, cumulative);
    }

    function getRecord(uint256 paymentId) external view returns (ReputationRecord memory) {
        return _records[paymentId];
    }

    function getRecordCount() external view returns (uint256) {
        return recordIds.length;
    }

    function getProviderStats(uint256 id) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            completedCount[id],
            failedCount[id],
            canceledCount[id],
            confirmedCount[id],
            notConfirmedCount[id],
            providerTransactionCount[id]
        );
    }

    function getServiceStats(bytes32 id)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (
            completedByService[id],
            failedByService[id],
            canceledByService[id],
            confirmedByService[id],
            notConfirmedByService[id],
            refundedAmountByService[id],
            serviceTransactionCount[id]
        );
    }

    function getBuyerStats(uint256 id) external view returns (uint256, uint256, uint256) {
        return (buyerTransactionCount[id], buyerConfirmedCount[id], buyerNotConfirmedCount[id]);
    }
}
