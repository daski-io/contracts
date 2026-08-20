// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsGuard} from "../interfaces/ISanctionsGuard.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

/// @notice Fail-closed screening against a Chainalysis-compatible oracle.
abstract contract SanctionsGuardUpgradeable is ISanctionsGuard {
    ISanctionsList public override sanctionsOracle;

    function __SanctionsGuard_init(address sanctionsOracle_) internal {
        if (sanctionsOracle_ == address(0) || sanctionsOracle_.code.length == 0) {
            revert SanctionsOracleUnavailable(sanctionsOracle_);
        }
        _readSanctions(sanctionsOracle_, address(0));
        sanctionsOracle = ISanctionsList(sanctionsOracle_);
    }

    function _requireNotSanctioned(address account) internal view {
        if (account == address(0)) return;
        if (_readSanctions(address(sanctionsOracle), account)) revert SanctionedAddress(account);
    }

    function _requireAgentParticipantsAllowed(address caller, address owner, address agentWallet) internal view {
        _requireNotSanctioned(caller);
        _requireNotSanctioned(owner);
        _requireNotSanctioned(agentWallet);
    }

    function _readSanctions(address oracle, address account) private view returns (bool) {
        (bool success, bytes memory data) = oracle.staticcall(abi.encodeCall(ISanctionsList.isSanctioned, (account)));
        if (!success || data.length != 32) revert SanctionsOracleUnavailable(oracle);

        uint256 result = abi.decode(data, (uint256));
        if (result > 1) revert SanctionsOracleUnavailable(oracle);
        return result == 1;
    }

    uint256[49] private __gap;
}
