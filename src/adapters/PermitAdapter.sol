// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IdentityRegistry} from "../IdentityRegistry.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IERC20Permit} from "../interfaces/IERC20Permit.sol";
import {IPermitAdapter} from "../interfaces/IPermitAdapter.sol";

/// @notice Adapter that settles payments via EIP-2612 `permit` + transferFrom.
///         Buyer (msg.sender) carries a permit signature granting this
///         ADAPTER allowance, then the adapter pulls funds and calls settle.
///
/// We follow the OZ-recommended try/permit pattern: if permit reverts (e.g.
/// frontrun by someone who submitted the same permit already), we continue
/// and rely on the existing allowance so the flow is resilient.
contract PermitAdapter is Initializable, UUPSUpgradeable, IPermitAdapter {
    using SafeERC20 for IERC20;

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

    /// @inheritdoc IPermitAdapter
    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        PermitData calldata permit
    ) external returns (uint256 paymentId) {
        require(router.isAcceptedToken(token), "token not accepted");

        uint256 buyerAgentId = identity.agentOfWallet(msg.sender);
        require(buyerAgentId != 0, "buyer has no agent");

        // Apply the permit. Using try/catch lets the flow survive a
        // frontrun where the permit was already consumed — the subsequent
        // transferFrom will still work if allowance is sufficient.
        try IERC20Permit(token)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
            catch {}

        // Pull funds from buyer straight into the router.
        IERC20(token).safeTransferFrom(msg.sender, address(router), amount);

        paymentId = router.settle(token, amount, serviceRef, buyerAgentId, providerAgentId);
    }

    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
