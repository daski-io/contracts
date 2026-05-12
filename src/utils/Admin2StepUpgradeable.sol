// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Shared 2-step admin transfer + UUPS upgrade gate for every Daski
///         contract. Each derived contract called `transferAdmin` /
///         `acceptAdmin` and gated `_authorizeUpgrade` on its own `admin`
///         field; pulling that into a base both removes ~25 LOC × 9 contracts
///         of duplication and keeps the transfer semantics impossible to
///         diverge across the stack.
///
/// Storage layout:
///   slot 0  — admin
///   slot 1  — pendingAdmin
///   slots 2..49 — reserved __gap so a future field added to this base does
///                 not collide with derived-contract storage.
abstract contract Admin2StepUpgradeable is Initializable, UUPSUpgradeable {
    address public admin;
    address public pendingAdmin;

    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    /// @dev Initialize the admin field. Call once from the derived contract's
    ///      initializer. Reverts on zero address.
    function __Admin2Step_init(address _admin) internal onlyInitializing {
        require(_admin != address(0), "zero admin");
        admin = _admin;
    }

    /// @notice Step 1 of admin transfer — propose `newAdmin`. A typo at this
    ///         step is recoverable. `newAdmin` must call `acceptAdmin` to
    ///         complete the handover.
    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Step 2 of admin transfer — accept ownership. Callable only by
    ///         the pendingAdmin set in step 1.
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, admin);
    }

    /// @dev UUPS upgrade authorization — admin only.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    uint256[48] private __gap;
}
