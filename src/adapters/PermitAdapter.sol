// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgentIndex} from "../interfaces/IAgentIndex.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IERC20Permit} from "../interfaces/IERC20Permit.sol";
import {IPermitAdapter} from "../interfaces/IPermitAdapter.sol";
import {Admin2StepUpgradeable} from "../utils/Admin2StepUpgradeable.sol";

/// @notice Adapter that settles payments via EIP-2612 `permit` + transferFrom.
///         Buyer (msg.sender) carries a permit signature granting this
///         ADAPTER allowance, then the adapter pulls funds and calls settle.
///
/// We follow the OZ-recommended try/permit pattern: if permit reverts (e.g.
/// frontrun by someone who submitted the same permit already), we continue
/// and rely on the existing allowance so the flow is resilient.
contract PermitAdapter is Admin2StepUpgradeable, IPermitAdapter {
    using SafeERC20 for IERC20;

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

    /// @inheritdoc IPermitAdapter
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        PermitData calldata permit
    ) external returns (uint256 paymentId) {
        require(router.isAcceptedToken(token), "token not accepted");

        // AgentIndex re-verifies the binding against the canonical ERC-8004
        // registry, so a stale wallet resolves to zero and reverts here.
        uint256 buyerAgentId = agentIndex.resolve(msg.sender);
        require(buyerAgentId != 0, "buyer has no agent");

        // Apply the permit. Using try/catch lets the flow survive a
        // frontrun where the permit was already consumed — the subsequent
        // transferFrom will still work if allowance is sufficient.
        try IERC20Permit(token)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
            catch {}

        // Pull funds from buyer straight into the router.
        IERC20(token).safeTransferFrom(msg.sender, address(router), amount);

        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, msg.sender, providerAgentId, serviceId);
    }

    uint256[50] private __gap;
}
