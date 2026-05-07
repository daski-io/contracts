// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Payment-rail-agnostic router interface. Whitelisted adapter
///         contracts arrange for funds to be moved into the router, then call
///         `settle` to split (provider / treasury) and record the payment.
///         Refunds are provider-initiated and partial/cumulative.
interface IPaymentRouter {
    struct PaymentRecord {
        uint256 buyerAgentId;
        uint256 providerAgentId;
        address token; // token used for this payment
        uint256 amount; // original gross amount
        address cachedBuyerWallet; // captured at settle; fallback for refund if agent unsets
        bytes32 serviceRef; // convenience for joins
        // Block timestamp at settlement. Used by ReputationStorage to derive
        // fulfillment time from the outcome attestation rather than trusting
        // the provider-supplied value. Appended at the end so existing
        // mapping entries from earlier deployments aren't rearranged on
        // upgrade — pre-upgrade entries read this slot as 0, which the
        // resolver treats as "unknown, fall back to attested value".
        uint256 paidAt;
    }

    /// @notice Adapter-facing settlement entry point. The adapter MUST have
    ///         transferred `amount` of `token` into this contract (router)
    ///         before calling. Router splits (provider/treasury), stores the
    ///         PaymentRecord, emits PaymentSettled, returns the new paymentId.
    function settle(address token, uint256 amount, bytes32 serviceRef, uint256 buyerAgentId, uint256 providerAgentId)
        external
        returns (uint256 paymentId);

    /// @notice Provider-initiated refund. The provider wallet (must be the
    ///         current agentWallet of `providerAgentId`) must have approved
    ///         this router for at least `amountToBuyer` of the ORIGINAL
    ///         payment token. Cumulative refunds are enforced to not exceed
    ///         the original amount.
    function refund(uint256 paymentId, uint256 amountToBuyer) external;

    // ── Views ────────────────────────────────────────────────────────
    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory);
    function refundedAmount(uint256 paymentId) external view returns (uint256);
    function serviceRefUsed(bytes32 serviceRef) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function isAcceptedToken(address token) external view returns (bool);
    function quoteCommission(uint256 amount) external view returns (uint256 commission, uint256 providerAmount);
}
