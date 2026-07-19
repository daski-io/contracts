// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "./interfaces/IEAS.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {ISchemaResolver} from "./interfaces/ISchemaResolver.sol";
import {ReputationAccounting} from "./reputation/ReputationAccounting.sol";

/// @notice EAS-backed bilateral reputation aggregator. PaymentRouter creates
///         every record atomically at settlement, so missing provider outcomes
///         remain visible in provider/service transaction totals. Providers
///         attest outcomes and buyers submit revocable confirmations.
contract ReputationStorage is ReputationAccounting, ISchemaResolver {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address identity_, address paymentRouter_, address admin_) external initializer {
        _initializeReputation(identity_, paymentRouter_, admin_);
    }

    function isPayable() external pure override returns (bool) {
        return false;
    }

    function attest(Attestation calldata attestation) external payable override onlyEAS returns (bool) {
        _handleAttest(attestation);
        return true;
    }

    function multiAttest(Attestation[] calldata attestations, uint256[] calldata)
        external
        payable
        override
        onlyEAS
        returns (bool)
    {
        for (uint256 i = 0; i < attestations.length; i++) {
            _handleAttest(attestations[i]);
        }
        return true;
    }

    function revoke(Attestation calldata attestation) external payable override onlyEAS returns (bool) {
        _handleRevoke(attestation);
        return true;
    }

    function multiRevoke(Attestation[] calldata attestations, uint256[] calldata)
        external
        payable
        override
        onlyEAS
        returns (bool)
    {
        for (uint256 i = 0; i < attestations.length; i++) {
            _handleRevoke(attestations[i]);
        }
        return true;
    }

    function _handleAttest(Attestation calldata a) internal {
        require(a.expirationTime == 0, "expiring attestations unsupported");
        require(a.revocationTime == 0, "attestation revoked");
        if (a.schema == outcomeSchema) {
            _onOutcomeAttest(a);
        } else if (a.schema == confirmationSchema) {
            _onConfirmationAttest(a);
        } else {
            revert("unknown schema");
        }
    }

    function _handleRevoke(Attestation calldata a) internal {
        if (a.schema == confirmationSchema) {
            _onConfirmationRevoke(a);
        } else if (a.schema == outcomeSchema) {
            revert("outcomes are not revocable");
        } else {
            revert("unknown schema");
        }
    }

    function _onOutcomeAttest(Attestation calldata a) internal {
        (uint256 paymentId, uint8 raw) = abi.decode(a.data, (uint256, uint8));
        require(raw <= uint8(TransactionOutcome.Canceled), "bad outcome");
        TransactionOutcome outcome = TransactionOutcome(raw);
        IPaymentRouter.PaymentRecord memory payment = paymentRouter.getPayment(paymentId);
        require(_controlsAgent(payment.providerAgentId, a.attester), "not provider for this payment");

        ReputationRecord storage record = _records[paymentId];
        require(record.paymentId != 0, "payment not recorded");
        require(!record.outcomeRecorded, "outcome already recorded");

        uint256 attestationDelay = block.timestamp - payment.paidAt;
        record.outcome = outcome;
        record.outcomeAttestationDelay = attestationDelay;
        record.outcomeTimestamp = block.timestamp;
        record.outcomeRecorded = true;

        if (outcome == TransactionOutcome.Completed) {
            completedCount[payment.providerAgentId]++;
            completedByService[record.serviceId]++;
        } else if (outcome == TransactionOutcome.Failed) {
            failedCount[payment.providerAgentId]++;
            failedByService[record.serviceId]++;
        } else {
            canceledCount[payment.providerAgentId]++;
            canceledByService[record.serviceId]++;
        }

        emit OutcomeRecorded(
            paymentId, payment.providerAgentId, payment.buyerAgentId, record.serviceId, outcome, attestationDelay, a.uid
        );
    }
}
