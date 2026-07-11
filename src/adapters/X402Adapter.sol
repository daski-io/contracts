// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIndex} from "../interfaces/IAgentIndex.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {IX402Adapter} from "../interfaces/IX402Adapter.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Adapter that settles x402 (EIP-3009 TransferWithAuthorization)
///         payments. Funds flow DIRECTLY from buyer → router via the token's
///         `transferWithAuthorization`; this adapter never holds funds.
///
/// The signed EIP-3009 authorization must have `to = router` so USDC
/// transfers directly into the router. After the transfer succeeds, this
/// adapter calls `router.settle(...)`.
///
/// AUTH BINDING — IMPORTANT FOR OFF-CHAIN SIGNERS:
///   The buyer's EIP-3009 signature commits only to (from, to, value,
///   validAfter, validBefore, nonce). It does NOT cover `serviceRef`,
///   `providerAgentId`, or `serviceId`, which are passed as separate
///   adapter call args. Without a binding, a frontrunner could pull the
///   buyer's funds and redirect them to a different (provider, service).
///   To prevent this, the buyer's signer MUST set:
///       nonce = keccak256(abi.encode(serviceRef, providerAgentId, serviceId))
///   This adapter rejects calls whose nonce does not match. The token's
///   per-(from, nonce) replay protection then doubles as a commitment to
///   exactly one (service, provider) pair per authorization.
contract X402Adapter is Admin2StepUpgradeable, IX402Adapter {
    IPaymentRouter public router;
    IAgentIndex public agentIndex;

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

    /// @inheritdoc IX402Adapter
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        EIP3009Auth calldata auth
    ) external returns (uint256 paymentId) {
        // Pre-flight: reject unknown tokens before burning gas on the
        // EIP-3009 transfer. The router will also re-check at settle.
        require(router.isAcceptedToken(token), "token not accepted");

        // Resolve the buyer's agentId from the signer. AgentIndex re-verifies
        // the binding against the canonical ERC-8004 registry — if the signer
        // transferred the agent away or rotated out between signing and
        // submission, this resolves to zero and the call reverts.
        uint256 buyerAgentId = agentIndex.resolve(auth.from);
        require(buyerAgentId != 0, "buyer has no agent");

        paymentId = _doSettle(token, amount, serviceRef, providerAgentId, serviceId, auth, buyerAgentId);
    }

    /// @notice Atomic registration + settle. If the buyer (auth.from) has no
    ///         agentId, the buyer's gasless registration consent signature is
    ///         used to mint one on the canonical ERC-8004 registry (via
    ///         AgentIndex.registerWithSig) in the same tx as the EIP-3009
    ///         transfer + router settlement. Either both succeed or both
    ///         revert. If the buyer is already registered, the registration
    ///         call is skipped and this behaves exactly like `settle`.
    /// @dev    The Sybil-tax for gasless registration is the USDC payment:
    ///         a spammer must spend `amount` of USDC to mint a fake agentId
    ///         via this path, since the registration only happens together
    ///         with a real settlement.
    function settleWithRegistration(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        EIP3009Auth calldata auth,
        string calldata agentURI,
        uint256 registrationDeadline,
        bytes calldata registrationSignature
    ) external returns (uint256 buyerAgentId, uint256 paymentId) {
        require(router.isAcceptedToken(token), "token not accepted");

        buyerAgentId = agentIndex.resolve(auth.from);
        if (buyerAgentId == 0) {
            buyerAgentId = agentIndex.registerWithSig(agentURI, auth.from, registrationDeadline, registrationSignature);
        }

        paymentId = _doSettle(token, amount, serviceRef, providerAgentId, serviceId, auth, buyerAgentId);
    }

    function _doSettle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        EIP3009Auth calldata auth,
        uint256 buyerAgentId
    ) internal returns (uint256 paymentId) {
        // Bind serviceRef + providerAgentId + serviceId into the EIP-3009
        // nonce. See contract-level NatSpec. Without this check, a
        // frontrunner could re-submit the buyer's auth with substituted call
        // args (different service or provider).
        require(auth.nonce == keccak256(abi.encode(serviceRef, providerAgentId, serviceId)), "auth not bound to call");

        // Pull funds: buyer -> router via EIP-3009. Token signature binds
        // the signer to exactly this `to=router` value.
        IERC3009(token)
            .transferWithAuthorization(
                auth.from,
                address(router),
                amount,
                auth.validAfter,
                auth.validBefore,
                auth.nonce,
                auth.v,
                auth.r,
                auth.s
            );

        // Router holds the funds now; delegate the split and bookkeeping.
        // auth.from is the payer wallet — cached by the router as the refund
        // fallback destination.
        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, auth.from, providerAgentId, serviceId);
    }

    /// @notice Helper for off-chain signers: returns the value the buyer
    ///         must use as the EIP-3009 `nonce` when authorizing a payment
    ///         for `(serviceRef, providerAgentId, serviceId)`. Pure — safe
    ///         to call off-chain via eth_call.
    function authNonceFor(bytes32 serviceRef, uint256 providerAgentId, bytes32 serviceId)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(serviceRef, providerAgentId, serviceId));
    }

    uint256[50] private __gap;
}
