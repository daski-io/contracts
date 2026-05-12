// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IdentityRegistry} from "../IdentityRegistry.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IApprovalAdapter} from "../interfaces/IApprovalAdapter.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Simplest adapter: buyer (msg.sender) must have pre-approved this
///         ADAPTER contract for `amount` of `token` (standard ERC-20
///         approve). The adapter pulls the funds into the router and calls
///         `router.settle(...)`.
///
/// Approval target is the adapter (not the router) so the adapter can safely
/// emit `safeTransferFrom` and keeps router semantics uniform — the router
/// only ever sees tokens arrive, never has external allowance to reason
/// about.
contract ApprovalAdapter is Admin2StepUpgradeable, IApprovalAdapter {
    using SafeERC20 for IERC20;

    IPaymentRouter public router;
    IdentityRegistry public identity;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _router, address _identity, address _admin) external initializer {
        require(_router != address(0), "zero router");
        require(_identity != address(0), "zero identity");
        __Admin2Step_init(_admin);
        router = IPaymentRouter(_router);
        identity = IdentityRegistry(_identity);
    }

    /// @inheritdoc IApprovalAdapter
    function settle(address token, uint256 amount, bytes32 serviceRef, uint256 providerAgentId, bytes32 serviceId)
        external
        returns (uint256 paymentId)
    {
        require(router.isAcceptedToken(token), "token not accepted");

        uint256 buyerAgentId = identity.agentOfWallet(msg.sender);
        require(buyerAgentId != 0, "buyer has no agent");

        IERC20(token).safeTransferFrom(msg.sender, address(router), amount);

        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, providerAgentId, serviceId);
    }

    uint256[50] private __gap;
}
