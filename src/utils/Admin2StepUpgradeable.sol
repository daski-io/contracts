// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SanctionsGuardUpgradeable} from "./SanctionsGuardUpgradeable.sol";
import {IExternalDependencyGuard} from "../interfaces/IExternalDependencyGuard.sol";

/// @notice Shared 2-step admin transfer + UUPS upgrade gate for every Daski
///         contract. Each derived contract called `transferAdmin` /
///         `acceptAdmin` and gated `_authorizeUpgrade` on its own `admin`
///         field; pulling that into a base both removes ~25 LOC × 9 contracts
///         of duplication and keeps the transfer semantics impossible to
///         diverge across the stack.
///
abstract contract Admin2StepUpgradeable is
    Initializable,
    UUPSUpgradeable,
    SanctionsGuardUpgradeable,
    IExternalDependencyGuard
{
    address public admin;
    address public pendingAdmin;
    address public pauseGuardian;
    bool public externalDependencyPaused;

    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier whenExternalDependencyOperational() {
        _requireExternalDependencyOperational();
        _;
    }

    function _requireExternalDependencyOperational() private view {
        require(!externalDependencyPaused, "external dependency paused");
    }

    /// @dev Initialize the admin field. Call once from the derived contract's
    ///      initializer. Reverts on zero address.
    function __Admin2Step_init(address _admin, address _sanctionsOracle) internal onlyInitializing {
        require(_admin != address(0), "zero admin");
        __SanctionsGuard_init(_sanctionsOracle);
        admin = _admin;
    }

    /// @notice Step 1 of admin transfer — propose `newAdmin`. A typo at this
    ///         step is recoverable. `newAdmin` must call `acceptAdmin` to
    ///         complete the handover.
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        _validateAdminTransfer(newAdmin);
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Step 2 of admin transfer — accept ownership. Callable only by
    ///         the pendingAdmin set in step 1.
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        _validateAdminTransfer(msg.sender);
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    function setPauseGuardian(address newGuardian) external onlyAdmin {
        require(newGuardian != address(0) || externalDependencyPaused, "zero guardian while operational");
        address oldGuardian = pauseGuardian;
        pauseGuardian = newGuardian;
        emit PauseGuardianUpdated(oldGuardian, newGuardian);
    }

    function pauseExternalDependency() external {
        require(msg.sender == admin || msg.sender == pauseGuardian, "not admin or guardian");
        if (!externalDependencyPaused) {
            externalDependencyPaused = true;
            emit ExternalDependencyPauseUpdated(true);
        }
    }

    function unpauseExternalDependency() external onlyAdmin {
        require(pauseGuardian != address(0), "zero guardian");
        if (externalDependencyPaused) {
            externalDependencyPaused = false;
            emit ExternalDependencyPauseUpdated(false);
        }
    }

    /// @dev UUPS upgrade authorization — admin only.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function _validateAdminTransfer(address) internal view virtual {}

    uint256[47] private __gap;
}
