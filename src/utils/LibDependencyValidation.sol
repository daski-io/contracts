// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IProviderRegistry} from "../interfaces/IProviderRegistry.sol";
import {IServiceRegistry} from "../interfaces/IServiceRegistry.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

/// @notice Fail-closed ABI and wiring checks for initializer dependencies.
library LibDependencyValidation {
    bytes4 private constant PROVIDER_IDENTITY_SELECTOR = bytes4(keccak256("identity()"));
    bytes4 private constant PROVIDER_TOKEN_SELECTOR = bytes4(keccak256("usdc()"));
    bytes4 private constant SERVICE_PROVIDER_SELECTOR = bytes4(keccak256("providerRegistry()"));
    bytes4 private constant SANCTIONS_ORACLE_SELECTOR = bytes4(keccak256("sanctionsOracle()"));

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

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(IERC20.totalSupply.selector));
        require(success && data.length == 32, "invalid usdc");

        (success, data) = candidate.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
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

    function requireServiceRegistry(address candidate, address expectedIdentity, address expectedProviderRegistry)
        internal
        view
    {
        require(candidate.code.length != 0, "service registry not contract");

        address wiredIdentity = _readAddress(candidate, PROVIDER_IDENTITY_SELECTOR, "invalid service registry");
        require(wiredIdentity == expectedIdentity, "service identity mismatch");
        address wiredProvider = _readAddress(candidate, SERVICE_PROVIDER_SELECTOR, "invalid service registry");
        require(wiredProvider == expectedProviderRegistry, "service provider mismatch");

        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeCall(IServiceRegistry.exists, (bytes32(type(uint256).max))));
        require(_isBool(success, data), "invalid service registry");
    }

    function requireProviderToken(address providerRegistry, address expectedToken) internal view {
        address wiredToken = _readAddress(providerRegistry, PROVIDER_TOKEN_SELECTOR, "invalid provider registry");
        require(wiredToken == expectedToken, "provider token mismatch");
    }

    function requireSanctionsOracle(address candidate) internal view {
        require(candidate.code.length != 0, "sanctions oracle not contract");
        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeCall(ISanctionsList.isSanctioned, (address(0))));
        require(_isBool(success, data), "invalid sanctions oracle");
    }

    function requireSanctionsBinding(address guardedContract, address expectedOracle) internal view {
        address wiredOracle = _readAddress(guardedContract, SANCTIONS_ORACLE_SELECTOR, "invalid sanctions binding");
        require(wiredOracle == expectedOracle, "sanctions binding mismatch");
    }

    function _readAddress(address candidate, bytes4 selector, string memory reason) private view returns (address) {
        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(selector));
        require(_isAddress(success, data), reason);
        return address(uint160(abi.decode(data, (uint256))));
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
