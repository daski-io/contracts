// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsList} from "./ISanctionsList.sol";

/// @notice Public sanctions-screening surface shared by Daski contracts.
interface ISanctionsGuard {
    error SanctionedAddress(address account);
    error SanctionsOracleUnavailable(address oracle);

    function sanctionsOracle() external view returns (ISanctionsList);
}
