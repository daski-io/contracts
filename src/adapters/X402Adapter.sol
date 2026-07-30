// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {IX402Adapter} from "../interfaces/IX402Adapter.sol";
import {AdapterBaseUpgradeable} from "./AdapterBaseUpgradeable.sol";

/// @notice Adapter that settles Daski's x402 V2 EIP-3009 receive profile.
///         Funds move buyer → adapter → router atomically, and both contracts
///         return to their exact pre-settlement balances after distribution.
///
/// The receive-authorization nonce is a commitment to the complete Daski
/// route plus a client-generated random salt. The facilitator sponsors gas
/// but cannot redirect a signed payment.
contract X402Adapter is AdapterBaseUpgradeable, ReentrancyGuard, IX402Adapter {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant DASKI_X402_RECEIVE_DOMAIN = keccak256("DASKI_X402_RECEIVE_V1");

    EnumerableSet.AddressSet private _authorizedFacilitators;

    modifier onlyAuthorizedFacilitator() {
        require(_authorizedFacilitators.contains(msg.sender), "facilitator not authorized");
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
        address expectedPayee,
        EIP3009Auth calldata auth,
        bytes32 nonceSalt
    ) external onlyAuthorizedFacilitator nonReentrant returns (uint256 paymentId) {
        _validatePreflight(token, amount, serviceRef, providerAgentId, serviceId, expectedPayee, auth, nonceSalt);

        uint256 buyerAgentId = _resolveBuyer(auth.from);
        paymentId = _doSettle(token, amount, serviceRef, providerAgentId, serviceId, expectedPayee, auth, buyerAgentId);
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
        address expectedPayee,
        EIP3009Auth calldata auth,
        bytes32 nonceSalt,
        string calldata agentURI,
        uint256 registrationDeadline,
        bytes calldata registrationSignature
    ) external onlyAuthorizedFacilitator nonReentrant returns (uint256 buyerAgentId, uint256 paymentId) {
        _validatePreflight(token, amount, serviceRef, providerAgentId, serviceId, expectedPayee, auth, nonceSalt);

        bool found;
        (buyerAgentId, found) = _tryResolveBuyer(auth.from);
        if (!found) {
            buyerAgentId = agentIndex.registerWithSig(agentURI, auth.from, registrationDeadline, registrationSignature);
        }

        paymentId = _doSettle(token, amount, serviceRef, providerAgentId, serviceId, expectedPayee, auth, buyerAgentId);
    }

    // Both callers hold the nonReentrant guard for the complete registration,
    // receive, routing, and balance-invariant sequence.
    // slither-disable-start reentrancy-balance
    function _doSettle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee,
        EIP3009Auth calldata auth,
        uint256 buyerAgentId
    ) internal returns (uint256 paymentId) {
        uint256 adapterBalanceBefore = IERC20(token).balanceOf(address(this));
        uint256 routerBalanceBefore = _routerBalance(token);
        IERC3009(token)
            .receiveWithAuthorization(
                auth.from, address(this), amount, auth.validAfter, auth.validBefore, auth.nonce, auth.signature
            );
        _requireExactBalanceIncrease(token, address(this), adapterBalanceBefore, amount);

        IERC20(token).safeTransfer(address(router), amount);
        _requireExactFunding(token, routerBalanceBefore, amount);
        paymentId = router.settle(
            token, amount, serviceRef, buyerAgentId, auth.from, providerAgentId, serviceId, expectedPayee
        );

        require(IERC20(token).balanceOf(address(this)) == adapterBalanceBefore, "adapter balance changed");
        require(_routerBalance(token) == routerBalanceBefore, "router balance changed");
    }
    // slither-disable-end reentrancy-balance

    function _validatePreflight(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee,
        EIP3009Auth calldata auth,
        bytes32 nonceSalt
    ) internal view {
        require(router.isAcceptedToken(token), "token not accepted");
        _requireNotSanctioned(auth.from);
        require(nonceSalt != bytes32(0), "zero nonce salt");
        require(
            auth.nonce
                == authNonceFor(
                    token,
                    auth.from,
                    amount,
                    auth.validAfter,
                    auth.validBefore,
                    serviceRef,
                    providerAgentId,
                    serviceId,
                    expectedPayee,
                    nonceSalt
                ),
            "auth not bound to call"
        );
    }

    function authNonceFor(
        address token,
        address payer,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee,
        bytes32 nonceSalt
    ) public view returns (bytes32) {
        // All fields are ABI-static, so concatenating these encoded segments
        // preserves the canonical payload while bounding compiler stack use.
        bytes memory paymentContext =
            abi.encode(DASKI_X402_RECEIVE_DOMAIN, block.chainid, address(this), address(router), token, payer, amount);
        bytes memory routeContext =
            abi.encode(validAfter, validBefore, providerAgentId, serviceId, expectedPayee, serviceRef, nonceSalt);
        return keccak256(bytes.concat(paymentContext, routeContext));
    }

    function setFacilitatorAuthorization(address facilitator, bool authorized) external onlyAdmin {
        require(facilitator != address(0), "zero facilitator");
        if (authorized) {
            _authorizedFacilitators.add(facilitator);
        } else {
            _authorizedFacilitators.remove(facilitator);
        }
        emit FacilitatorAuthorizationSet(facilitator, authorized);
    }

    function authorizedFacilitators(address facilitator) external view returns (bool) {
        return _authorizedFacilitators.contains(facilitator);
    }

    function getFacilitatorCount() external view returns (uint256) {
        return _authorizedFacilitators.length();
    }

    function getFacilitatorAt(uint256 index) external view returns (address) {
        return _authorizedFacilitators.at(index);
    }

    function _requireExactBalanceIncrease(address token, address account, uint256 balanceBefore, uint256 amount)
        private
        view
    {
        uint256 balanceAfter = IERC20(token).balanceOf(account);
        require(balanceAfter >= balanceBefore && balanceAfter - balanceBefore == amount, "unexpected token amount");
    }

    uint256[48] private __gap;
}
