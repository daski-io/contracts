// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC3009} from "../interfaces/IERC3009.sol";
import {IX402Adapter} from "../interfaces/IX402Adapter.sol";
import {AdapterBaseUpgradeable} from "./AdapterBaseUpgradeable.sol";

/// @notice Adapter that settles x402 (EIP-3009 TransferWithAuthorization)
///         payments. Funds flow DIRECTLY from buyer → router via the token's
///         `transferWithAuthorization`; this adapter never holds funds.
///
/// The signed EIP-3009 authorization must have `to = router` so USDC
/// transfers directly into the router. After the transfer succeeds, this
/// adapter calls `router.settle(...)`.
///
/// TRUST BOUNDARY:
///   The buyer's EIP-3009 signature commits only to (from, to, value,
///   validAfter, validBefore, nonce). It does NOT cover `serviceRef`,
///   `providerAgentId`, or `serviceId`, which are passed as separate
///   adapter call args. Only an administrator-authorized Daski facilitator
///   may select those routing fields. The facilitator resolves them from
///   its persisted payment challenge before calling this adapter.
contract X402Adapter is AdapterBaseUpgradeable, IX402Adapter {
    mapping(address facilitator => bool authorized) public authorizedFacilitators;

    modifier onlyAuthorizedFacilitator() {
        require(authorizedFacilitators[msg.sender], "facilitator not authorized");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _router, address _agentIndex, address _sanctionsOracle, address _admin)
        external
        initializer
    {
        __AdapterBase_init(_router, _agentIndex, _sanctionsOracle, _admin);
    }

    /// @inheritdoc IX402Adapter
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        EIP3009Auth calldata auth
    ) external onlyAuthorizedFacilitator returns (uint256 paymentId) {
        // Pre-flight: reject unknown tokens before burning gas on the
        // EIP-3009 transfer. The router will also re-check at settle.
        require(router.isAcceptedToken(token), "token not accepted");
        _requireNotSanctioned(auth.from);

        // Resolve the buyer's agentId from the signer. AgentIndex re-verifies
        // the binding against the canonical ERC-8004 registry — if the signer
        // transferred the agent away or rotated out between signing and
        // submission, this returns found=false and the call reverts.
        uint256 buyerAgentId = _resolveBuyer(auth.from);

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
    ) external onlyAuthorizedFacilitator returns (uint256 buyerAgentId, uint256 paymentId) {
        require(router.isAcceptedToken(token), "token not accepted");
        _requireNotSanctioned(auth.from);

        bool found;
        (buyerAgentId, found) = _tryResolveBuyer(auth.from);
        if (!found) {
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
        // Pull funds: buyer -> router via EIP-3009. Token signature binds
        // the signer to exactly this `to=router` value.
        uint256 balanceBefore = _routerBalance(token);
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
        _requireExactFunding(token, balanceBefore, amount);

        // Router holds the funds now; delegate the split and bookkeeping.
        // auth.from is the payer wallet — cached by the router as the refund
        // fallback destination.
        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, auth.from, providerAgentId, serviceId);
    }

    /// @notice Add or revoke a facilitator allowed to submit Daski routing
    ///         fields alongside standard x402 EIP-3009 authorizations.
    function setFacilitatorAuthorization(address facilitator, bool authorized) external onlyAdmin {
        require(facilitator != address(0), "zero facilitator");
        authorizedFacilitators[facilitator] = authorized;
        emit FacilitatorAuthorizationSet(facilitator, authorized);
    }

    uint256[49] private __gap;
}
