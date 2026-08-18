// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ReputationIdentityDependencyStub {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721).interfaceId;
    }

    function getAgentWallet(uint256) external pure returns (address) {
        return address(0);
    }
}

contract ReputationUsdcDependencyStub {
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract ReputationProviderDependencyStub {
    address public identity;
    address public usdc;
    address public sanctionsOracle;

    constructor(address identity_, address usdc_, address sanctionsOracle_) {
        identity = identity_;
        usdc = usdc_;
        sanctionsOracle = sanctionsOracle_;
    }

    function isRegistered(uint256) external pure returns (bool) {
        return false;
    }

    function setSanctionsOracle(address value) external {
        sanctionsOracle = value;
    }
}

contract ReputationServiceDependencyStub {
    address public identity;
    address public providerRegistry;
    address public sanctionsOracle;

    constructor(address identity_, address providerRegistry_, address sanctionsOracle_) {
        identity = identity_;
        providerRegistry = providerRegistry_;
        sanctionsOracle = sanctionsOracle_;
    }

    function exists(bytes32) external pure returns (bool) {
        return false;
    }
}
