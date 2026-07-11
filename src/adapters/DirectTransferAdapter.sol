// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIndex} from "../interfaces/IAgentIndex.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Adapter that attributes x402 payments settled by an EXTERNAL
///         facilitator (e.g. the Coinbase CDP facilitator). Those facilitators
///         submit the buyer's EIP-3009 authorization as a bare
///         `transferWithAuthorization` on the token itself — funds land on the
///         PaymentRouter, but `router.settle(...)` (commission split, payment
///         record, reputation) never runs. A whitelisted attributor (the Daski
///         gateway) calls `attribute` afterwards to run the split and
///         bookkeeping for funds that already arrived.
///
/// Why this exists: x402 Bazaar indexing requires the CDP facilitator itself
/// to settle payments for a resource. CDP settles the `exact` scheme by
/// calling `transferWithAuthorization` directly on USDC, so Daski's split
/// cannot run in that transaction. This adapter decouples the transfer
/// (submitted by CDP) from the attribution (submitted by the gateway) while
/// keeping the split, serviceRef uniqueness, and PaymentRecord invariants in
/// the audited router.
///
/// TRUST MODEL — read before touching:
///   * `attribute` is restricted to whitelisted attributors, NOT
///     permissionless. EIP-3009 `authorizationState(from, nonce)` records
///     only that SOME authorization with that nonce was consumed — not its
///     recipient or value. A buyer can sign two authorizations over the same
///     nonce (one `to=router`, one `to=self`), execute the self-transfer, and
///     present the router-targeted signature as "proof" of payment. Only the
///     off-chain attributor, which watched the external facilitator settle
///     the specific (to=router, value=amount) transaction, can rule that out
///     — so attribution authority stays with it.
///   * The router's own under-funding check (`balanceOf(router) >= amount`
///     inside `settle`) bounds the damage of a buggy attributor: total
///     attributed can never exceed what the router actually holds.
///   * serviceRef single-use (enforced by the router) makes attribution
///     idempotent — a crashed gateway can safely retry.
///   * The `authorizationState` require is defense-in-depth against an
///     attributor bug attributing a payment whose transfer never happened;
///     it cannot substitute for the attributor's off-chain check (see above).
///
/// Unlike X402Adapter there is no nonce binding to (serviceRef,
/// providerAgentId, serviceId): external x402 clients choose random nonces.
/// The binding of an authorization to a specific Daski service lives in the
/// attributor's challenge store, which is why only it may attribute.
contract DirectTransferAdapter is Admin2StepUpgradeable {
    IPaymentRouter public router;
    IAgentIndex public agentIndex;

    /// @notice Off-chain services allowed to attribute externally settled
    ///         transfers. In practice: the Daski gateway's facilitator wallet.
    mapping(address => bool) public attributors;

    event AttributorSet(address indexed attributor, bool allowed);
    event DirectTransferAttributed(
        uint256 indexed paymentId, bytes32 indexed serviceRef, address indexed from, bytes32 authNonce
    );

    modifier onlyAttributor() {
        require(attributors[msg.sender], "not attributor");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _router, address _agentIndex, address _admin) external initializer {
        require(_router != address(0), "zero router");
        require(_agentIndex != address(0), "zero agent index");
        __Admin2Step_init(_admin);
        router = IPaymentRouter(_router);
        agentIndex = IAgentIndex(_agentIndex);
    }

    /// @notice Run the router split + bookkeeping for a payment whose funds
    ///         were already transferred to the router by an external
    ///         facilitator via a bare EIP-3009 `transferWithAuthorization`.
    /// @dev    The attributor MUST have verified off-chain that the consumed
    ///         authorization had `to == router` and `value == amount` (it saw
    ///         the external facilitator's settle response / transaction).
    /// @param  token            ERC-20 the payment was made in (router-accepted).
    /// @param  amount           Gross amount that arrived at the router.
    /// @param  serviceRef       Gateway-issued single-use payment reference.
    /// @param  providerAgentId  ERC-8004 agentId of the provider being paid.
    /// @param  serviceId        ServiceRegistry row this payment is bound to.
    /// @param  from             Buyer wallet that signed the authorization.
    /// @param  authNonce        EIP-3009 nonce of the consumed authorization
    ///                          (client-chosen, no structural meaning here).
    function attribute(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address from,
        bytes32 authNonce
    ) external onlyAttributor returns (uint256 paymentId) {
        require(router.isAcceptedToken(token), "token not accepted");
        require(IERC3009(token).authorizationState(from, authNonce), "authorization not consumed");

        // Resolve the buyer's agentId from the signer wallet — same
        // live-lookup semantics as X402Adapter (AgentIndex re-verifies the
        // binding against the canonical ERC-8004 registry). External-rail
        // buyers must be registered before paying; there is no
        // atomic-register variant because external facilitators can't carry
        // the registration sig.
        uint256 buyerAgentId = agentIndex.resolve(from);
        require(buyerAgentId != 0, "buyer has no agent");

        // Router re-checks: accepted token, serviceRef unused, provider and
        // service active, and — critically — that its balance actually
        // covers `amount` before paying out.
        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, from, providerAgentId, serviceId);

        emit DirectTransferAttributed(paymentId, serviceRef, from, authNonce);
    }

    function setAttributor(address attributor, bool allowed) external onlyAdmin {
        require(attributor != address(0), "zero attributor");
        attributors[attributor] = allowed;
        emit AttributorSet(attributor, allowed);
    }

    uint256[50] private __gap;
}
