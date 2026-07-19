// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC3009} from "../interfaces/IERC3009.sol";
import {AdapterBaseUpgradeable} from "./AdapterBaseUpgradeable.sol";

/// @notice Adapter that attributes x402 payments settled by an EXTERNAL
///         facilitator (e.g. the Coinbase CDP facilitator). Those facilitators
///         submit the buyer's EIP-3009 authorization as a bare
///         `transferWithAuthorization` on the token itself — funds land on the
///         PaymentRouter, but `router.settle(...)` (commission split, payment
///         record, reputation) never runs. A whitelisted attributor (the Daski
///         gateway) first reserves the observed deposit, then attributes it.
///         The reservation prevents unrelated settlements from consuming the
///         balance and can be returned to the original payer if attribution
///         cannot complete.
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
///   * Each consumed authorization can create one reservation only. A
///     reservation is bound to this adapter, token, amount, and payer.
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
contract DirectTransferAdapter is AdapterBaseUpgradeable {
    /// @notice Off-chain services allowed to attribute externally settled
    ///         transfers. In practice: the Daski gateway's facilitator wallet.
    mapping(address => bool) public attributors;
    mapping(bytes32 => bool) private _processedAuthorizations;

    event AttributorSet(address indexed attributor, bool allowed);
    event DirectTransferAttributed(
        uint256 indexed paymentId, bytes32 indexed serviceRef, address indexed from, bytes32 authNonce
    );
    event DirectTransferReserved(
        bytes32 indexed depositId, address indexed token, address indexed from, bytes32 authNonce, uint256 amount
    );
    event DirectTransferRefunded(
        bytes32 indexed depositId, address indexed token, address indexed from, bytes32 authNonce
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
        __AdapterBase_init(_router, _agentIndex, _admin);
    }

    /// @notice Reserve a payment observed by the attributor after the
    ///         facilitator transferred funds to the router.
    function registerDeposit(address token, uint256 amount, address from, bytes32 authNonce) external onlyAttributor {
        require(router.isAcceptedToken(token), "token not accepted");
        require(IERC3009(token).authorizationState(from, authNonce), "authorization not consumed");

        bytes32 depositId = _depositId(token, from, authNonce);
        require(!_processedAuthorizations[depositId], "authorization already processed");
        _processedAuthorizations[depositId] = true;

        router.reserveDeposit(token, depositId, amount, from);
        emit DirectTransferReserved(depositId, token, from, authNonce, amount);
    }

    /// @notice Run the router split and bookkeeping for a previously reserved
    ///         external payment.
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
        // Resolve the buyer's agentId from the signer wallet — same
        // live-lookup semantics as X402Adapter (AgentIndex re-verifies the
        // binding against the canonical ERC-8004 registry). External-rail
        // buyers must be registered before paying; there is no
        // atomic-register variant because external facilitators can't carry
        // the registration sig.
        uint256 buyerAgentId = _resolveBuyer(from);

        bytes32 depositId = _depositId(token, from, authNonce);
        paymentId =
            router.settleReserved(token, amount, serviceRef, buyerAgentId, from, providerAgentId, serviceId, depositId);

        emit DirectTransferAttributed(paymentId, serviceRef, from, authNonce);
    }

    /// @notice Return a reserved payment to its original payer. The payer can
    ///         recover directly if business validation fails; an attributor
    ///         may also perform the refund as part of its reconciliation job.
    function refundDeposit(address token, address from, bytes32 authNonce) external {
        require(msg.sender == from || attributors[msg.sender], "not depositor or attributor");
        bytes32 depositId = _depositId(token, from, authNonce);
        router.refundReservedDeposit(token, depositId);
        emit DirectTransferRefunded(depositId, token, from, authNonce);
    }

    function setAttributor(address attributor, bool allowed) external onlyAdmin {
        require(attributor != address(0), "zero attributor");
        attributors[attributor] = allowed;
        emit AttributorSet(attributor, allowed);
    }

    function authorizationProcessed(address token, address from, bytes32 authNonce) external view returns (bool) {
        return _processedAuthorizations[_depositId(token, from, authNonce)];
    }

    function _depositId(address token, address from, bytes32 authNonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, from, authNonce));
    }

    uint256[50] private __gap;
}
