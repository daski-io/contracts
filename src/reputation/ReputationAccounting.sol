// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IEAS} from "../interfaces/IEAS.sol";
import {ReputationConfirmation} from "./ReputationConfirmation.sol";

/// @notice Payment/refund accounting, aggregate views, and immutable-history
///         configuration guards.
abstract contract ReputationAccounting is ReputationConfirmation {
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
            outcomeRecorded: false
        });
        recordIds.push(paymentId);
        providerTransactionCount[payment.providerAgentId]++;
        serviceTransactionCount[payment.serviceId]++;
        buyerTransactionCount[payment.buyerAgentId]++;
        emit PaymentRecorded(paymentId, payment.providerAgentId, payment.buyerAgentId, payment.serviceId);
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

    function getRefundedAmount(uint256 paymentId) external view returns (uint256) {
        return refundedAmount[paymentId];
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

    function setPaymentRouter(address newRouter) external onlyAdmin {
        require(newRouter != address(0), "zero router");
        require(recordIds.length == 0, "records exist");
        address oldRouter = address(paymentRouter);
        paymentRouter = IPaymentRouter(newRouter);
        emit PaymentRouterUpdated(oldRouter, newRouter);
    }

    function setEAS(address newEAS) external onlyAdmin {
        require(newEAS != address(0), "zero eas");
        require(recordIds.length == 0, "records exist");
        address oldEAS = address(eas);
        eas = IEAS(newEAS);
        emit EASUpdated(oldEAS, newEAS);
    }

    function setOutcomeSchema(bytes32 newSchema) external onlyAdmin {
        require(newSchema != bytes32(0), "zero schema");
        require(recordIds.length == 0, "records exist");
        require(newSchema != confirmationSchema, "schemas must differ");
        bytes32 oldSchema = outcomeSchema;
        outcomeSchema = newSchema;
        emit OutcomeSchemaUpdated(oldSchema, newSchema);
    }

    function setConfirmationSchema(bytes32 newSchema) external onlyAdmin {
        require(newSchema != bytes32(0), "zero schema");
        require(recordIds.length == 0, "records exist");
        require(newSchema != outcomeSchema, "schemas must differ");
        bytes32 oldSchema = confirmationSchema;
        confirmationSchema = newSchema;
        emit ConfirmationSchemaUpdated(oldSchema, newSchema);
    }
}
