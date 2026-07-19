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
        bytes32 serviceId; // ServiceRegistry serviceId this payment was for
        address token; // token used for this payment
        uint256 amount; // original gross amount
        // Payer wallet captured at settle (adapter-supplied, router-verified
        // against the buyer agent). Refunds always return to this wallet so
        // later agent ownership or wallet changes cannot redirect them.
        address cachedBuyerWallet;
        // Provider controllers captured at settlement. Historical reputation
        // attestations remain bound to the parties that accepted the payment.
        address cachedProviderOwner;
        address cachedProviderWallet;
        bytes32 serviceRef; // adapter-supplied reference, single-use
        // Block timestamp at settlement. Used by ReputationStorage to derive
        // the outcome attestation delay.
        uint256 paidAt;
    }

    /// @notice Adapter-facing settlement entry point. The adapter MUST have
    ///         transferred `amount` of `token` into this contract (router)
    ///         before calling. Router validates the (provider, service) pair
    ///         against ServiceRegistry, splits funds (provider/treasury),
    ///         stores the PaymentRecord, emits PaymentSettled, returns the
    ///         new paymentId.
    /// @dev    `serviceId` MUST belong to `providerAgentId` and the service
    ///         MUST be active. Payee resolution: serviceWallet if set, else
    ///         the provider's ERC-8004 agentWallet on the canonical registry.
    ///         `buyerWallet` is the payer wallet; the router verifies it
    ///         currently controls `buyerAgentId` (verified agentWallet or
    ///         ERC-721 owner) and caches it as the refund fallback.
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 buyerAgentId,
        address buyerWallet,
        uint256 providerAgentId,
        bytes32 serviceId
    ) external returns (uint256 paymentId);

    /// @notice Provider-initiated refund. Authorized callers are: NFT owner,
    ///         ERC-721 operator (isApprovedForAll), per-token approved
    ///         spender (getApproved), or the provider's current agentWallet.
    ///         Source of funds is `msg.sender` — the caller must have
    ///         approved the router for at least `amountToBuyer` of the
    ///         original payment token. Cumulative refunds are capped at the
    ///         original payment amount.
    function refund(uint256 paymentId, uint256 amountToBuyer) external;

    // ── Views ────────────────────────────────────────────────────────
    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory);
    function refundedAmount(uint256 paymentId) external view returns (uint256);
    function serviceRefUsed(bytes32 serviceRef) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function isAcceptedToken(address token) external view returns (bool);
    function quoteCommission(uint256 amount) external view returns (uint256 commission, uint256 providerAmount);
}
