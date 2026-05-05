// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IdentityRegistry} from "../IdentityRegistry.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {IX402Adapter} from "../interfaces/IX402Adapter.sol";

/// @notice Adapter that settles x402 (EIP-3009 TransferWithAuthorization)
///         payments. Funds flow DIRECTLY from buyer → router via the token's
///         `transferWithAuthorization`; this adapter never holds funds.
///
/// The signed EIP-3009 authorization must have `to = router` so USDC
/// transfers directly into the router. After the transfer succeeds, this
/// adapter calls `router.settle(...)`.
contract X402Adapter is Initializable, UUPSUpgradeable, IX402Adapter {
    IPaymentRouter public router;
    IdentityRegistry public identity;
    address public admin;
    address public pendingAdmin;

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _router, address _identity, address _admin) external initializer {
        require(_router != address(0), "zero router");
        require(_identity != address(0), "zero identity");
        require(_admin != address(0), "zero admin");
        router = IPaymentRouter(_router);
        identity = IdentityRegistry(_identity);
        admin = _admin;
    }

    /// @inheritdoc IX402Adapter
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        EIP3009Auth calldata auth
    ) external returns (uint256 paymentId) {
        // Pre-flight: reject unknown tokens before burning gas on the
        // EIP-3009 transfer. The router will also re-check at settle.
        require(router.isAcceptedToken(token), "token not accepted");

        // Resolve the buyer's agentId from the signer. Using agentOfWallet
        // honors ERC-8004 wallet rotation — if the signer just rotated
        // their wallet between signing and submission, the call reverts.
        uint256 buyerAgentId = identity.agentOfWallet(auth.from);
        require(buyerAgentId != 0, "buyer has no agent");

        paymentId = _doSettle(token, amount, serviceRef, providerAgentId, auth, buyerAgentId);
    }

    /// @notice Atomic registration + settle. If the buyer (auth.from) has no
    ///         agentId, the buyer's gasless registerBySig signature is used
    ///         to mint one in the same tx as the EIP-3009 transfer + router
    ///         settlement. Either both succeed or both revert. If the buyer
    ///         is already registered, the registration call is skipped and
    ///         this behaves exactly like `settle`.
    /// @dev    The Sybil-tax for gasless registration is the USDC payment:
    ///         a spammer must spend `amount` of USDC to mint a fake agentId
    ///         via this path, since the registration only happens together
    ///         with a real settlement.
    function settleWithRegistration(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        EIP3009Auth calldata auth,
        string calldata agentURI,
        uint256 registrationDeadline,
        bytes calldata registrationSignature
    ) external returns (uint256 buyerAgentId, uint256 paymentId) {
        require(router.isAcceptedToken(token), "token not accepted");

        buyerAgentId = identity.agentOfWallet(auth.from);
        if (buyerAgentId == 0) {
            buyerAgentId = identity.registerBySig(agentURI, auth.from, registrationDeadline, registrationSignature);
        }

        paymentId = _doSettle(token, amount, serviceRef, providerAgentId, auth, buyerAgentId);
    }

    function _doSettle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        EIP3009Auth calldata auth,
        uint256 buyerAgentId
    ) internal returns (uint256 paymentId) {
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
        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, providerAgentId);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
