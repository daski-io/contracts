// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsList} from "../../src/interfaces/ISanctionsList.sol";

contract MockSanctionsList is ISanctionsList {
    mapping(address => bool) private _sanctioned;
    bool private _revertChecks;

    function setSanctioned(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }

    function setRevertChecks(bool value) external {
        _revertChecks = value;
    }

    function isSanctioned(address account) external view returns (bool) {
        require(!_revertChecks, "oracle unavailable");
        return _sanctioned[account];
    }
}

contract EmptySanctionsList {
    fallback() external {}
}

contract MalformedSanctionsList {
    fallback() external {
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}
