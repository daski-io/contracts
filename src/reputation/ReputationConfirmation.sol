// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "../interfaces/IEAS.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {LibAgentAuth} from "../utils/LibAgentAuth.sol";
import {ReputationStorageBase} from "./ReputationStorageBase.sol";

/// @notice Buyer confirmation revisions and revocations.
abstract contract ReputationConfirmation is ReputationStorageBase {
    function _onConfirmationAttest(Attestation calldata a) internal {
        (uint256 paymentId, uint8 raw) = abi.decode(a.data, (uint256, uint8));
        require(
            raw == uint8(BuyerConfirmation.Confirmed) || raw == uint8(BuyerConfirmation.NotConfirmed),
            "binary confirmation only"
        );
        BuyerConfirmation confirmation = BuyerConfirmation(raw);
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        require(_controlsAgent(payment.buyerAgentId, a.attester), "not buyer for this payment");

        ReputationRecord storage record = _records[paymentId];
        require(record.paymentId != 0, "payment not recorded");

        if (a.refUID != bytes32(0)) {
            require(a.refUID != a.uid, "self refUID");
            BuyerConfirmation old = confirmationByUid[a.refUID];
            require(old != BuyerConfirmation.Pending, "refUID is not a tracked confirmation");
            require(paymentIdByUid[a.refUID] == paymentId, "refUID belongs to different payment");
            _decrementConfirmation(payment, record.serviceId, old);
            delete confirmationByUid[a.refUID];
            delete paymentIdByUid[a.refUID];
        } else {
            require(record.confirmation == BuyerConfirmation.Pending, "must ref prior confirmation");
        }

        record.confirmation = confirmation;
        record.confirmationTimestamp = block.timestamp;
        _incrementConfirmation(payment, record.serviceId, confirmation);
        confirmationByUid[a.uid] = confirmation;
        paymentIdByUid[a.uid] = paymentId;

        emit BuyerConfirmationSubmitted(
            paymentId, payment.providerAgentId, payment.buyerAgentId, record.serviceId, confirmation, a.uid, a.refUID
        );
    }

    function _onConfirmationRevoke(Attestation calldata a) internal {
        BuyerConfirmation old = confirmationByUid[a.uid];
        if (old == BuyerConfirmation.Pending) return;

        uint256 paymentId = paymentIdByUid[a.uid];
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        ReputationRecord storage record = _records[paymentId];
        _decrementConfirmation(payment, record.serviceId, old);
        delete confirmationByUid[a.uid];
        delete paymentIdByUid[a.uid];

        if (record.confirmation == old) {
            record.confirmation = BuyerConfirmation.Pending;
            record.confirmationTimestamp = 0;
        }
    }

    function _incrementConfirmation(
        IPaymentRouter.PaymentRecord memory payment,
        bytes32 serviceId,
        BuyerConfirmation confirmation
    ) private {
        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[payment.providerAgentId]++;
            confirmedByService[serviceId]++;
            buyerConfirmedCount[payment.buyerAgentId]++;
        } else {
            notConfirmedCount[payment.providerAgentId]++;
            notConfirmedByService[serviceId]++;
            buyerNotConfirmedCount[payment.buyerAgentId]++;
        }
    }

    function _decrementConfirmation(
        IPaymentRouter.PaymentRecord memory payment,
        bytes32 serviceId,
        BuyerConfirmation confirmation
    ) private {
        if (confirmation == BuyerConfirmation.Confirmed) {
            confirmedCount[payment.providerAgentId]--;
            confirmedByService[serviceId]--;
            buyerConfirmedCount[payment.buyerAgentId]--;
        } else {
            notConfirmedCount[payment.providerAgentId]--;
            notConfirmedByService[serviceId]--;
            buyerNotConfirmedCount[payment.buyerAgentId]--;
        }
    }

    function _controlsAgent(uint256 agentId, address who) internal view returns (bool) {
        return LibAgentAuth.isOwnerOrAgentWallet(identity, agentId, who);
    }
}
