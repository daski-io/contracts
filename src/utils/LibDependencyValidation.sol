// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IProviderRegistry} from "../interfaces/IProviderRegistry.sol";

/// @notice Basic interface and wiring checks for initializer dependencies.
/// @dev Deployment validation owns exact address and implementation identity.
library LibDependencyValidation {
    bytes4 private constant PROVIDER_IDENTITY_SELECTOR = bytes4(keccak256("identity()"));

    function requireIdentity(address candidate) internal view {
        require(candidate.code.length != 0, "identity not contract");

        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeCall(IERC165.supportsInterface, (type(IERC721).interfaceId)));
        require(_isTrue(success, data), "invalid identity");

        (success, data) = candidate.staticcall(abi.encodeCall(IIdentityRegistry.getAgentWallet, (type(uint256).max)));
        require(_isAddress(success, data), "invalid identity");
    }

    function requireUsdc(address candidate) internal view {
        require(candidate.code.length != 0, "usdc not contract");

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        require(success && data.length == 32, "invalid usdc");

        (success, data) = candidate.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        require(success && data.length == 32 && abi.decode(data, (uint256)) == 6, "invalid usdc");
    }

    function requireProviderRegistry(address candidate, address expectedIdentity) internal view {
        require(candidate.code.length != 0, "provider registry not contract");

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(PROVIDER_IDENTITY_SELECTOR));
        require(_isAddress(success, data), "invalid provider registry");
        require(address(uint160(abi.decode(data, (uint256)))) == expectedIdentity, "provider identity mismatch");

        (success, data) = candidate.staticcall(abi.encodeCall(IProviderRegistry.isRegistered, (type(uint256).max)));
        require(_isBool(success, data), "invalid provider registry");
    }

    function _isAddress(bool success, bytes memory data) private pure returns (bool) {
        return success && data.length == 32 && abi.decode(data, (uint256)) <= type(uint160).max;
    }

    function _isBool(bool success, bytes memory data) private pure returns (bool) {
        return success && data.length == 32 && abi.decode(data, (uint256)) <= 1;
    }

    function _isTrue(bool success, bytes memory data) private pure returns (bool) {
        return success && data.length == 32 && abi.decode(data, (uint256)) == 1;
    }
}
