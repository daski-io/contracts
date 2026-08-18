// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ICircleUSDC, StandardRailCircleUSDC} from "./StandardRailCircleUSDC.sol";

/// @notice Reads Circle USDC identity and route health from one exact historical block.
abstract contract StandardRailCircleUSDCActivation is Script {
    function _historicalCircleSnapshot(
        address token,
        address splitter,
        address provider,
        address daski,
        string memory blockReference
    ) internal returns (StandardRailCircleUSDC.Snapshot memory snapshot) {
        snapshot.proxyCodeHash = _historicalCodeHash(token, blockReference);
        snapshot.implementation =
            _historicalAddress(token, abi.encodeCall(ICircleUSDC.implementation, ()), blockReference);
        snapshot.implementationCodeHash = _historicalCodeHash(snapshot.implementation, blockReference);
        snapshot.nameHash = _historicalStringHash(token, abi.encodeCall(ICircleUSDC.name, ()), blockReference);
        snapshot.symbolHash = _historicalStringHash(token, abi.encodeCall(ICircleUSDC.symbol, ()), blockReference);
        snapshot.currencyHash = _historicalStringHash(token, abi.encodeCall(ICircleUSDC.currency, ()), blockReference);
        snapshot.decimals = _historicalUint(token, abi.encodeCall(ICircleUSDC.decimals, ()), blockReference);
        snapshot.versionHash = _historicalStringHash(token, abi.encodeCall(ICircleUSDC.version, ()), blockReference);
        snapshot.pauser = _historicalAddress(token, abi.encodeCall(ICircleUSDC.pauser, ()), blockReference);
        snapshot.blacklister = _historicalAddress(token, abi.encodeCall(ICircleUSDC.blacklister, ()), blockReference);
        snapshot.paused = _historicalBool(token, abi.encodeCall(ICircleUSDC.paused, ()), blockReference);
        snapshot.splitterBlacklisted =
            _historicalBool(token, abi.encodeCall(ICircleUSDC.isBlacklisted, (splitter)), blockReference);
        snapshot.providerBlacklisted =
            _historicalBool(token, abi.encodeCall(ICircleUSDC.isBlacklisted, (provider)), blockReference);
        snapshot.daskiBlacklisted =
            _historicalBool(token, abi.encodeCall(ICircleUSDC.isBlacklisted, (daski)), blockReference);
    }

    function _historicalCodeHash(address target, string memory blockReference) internal returns (bytes32) {
        bytes memory code = vm.rpc("eth_getCode", string.concat("[\"", vm.toString(target), "\",", blockReference, "]"));
        require(code.length != 0, "historical code missing");
        return keccak256(code);
    }

    function _historicalCall(address target, bytes memory callData, string memory blockReference)
        internal
        returns (bytes memory result)
    {
        result = vm.rpc(
            "eth_call",
            string.concat(
                "[{\"to\":\"", vm.toString(target), "\",\"data\":\"", vm.toString(callData), "\"},", blockReference, "]"
            )
        );
    }

    function _historicalUint(address target, bytes memory callData, string memory blockReference)
        internal
        returns (uint256 value)
    {
        bytes memory result = _historicalCall(target, callData, blockReference);
        require(result.length == 32, "invalid historical uint result");
        value = abi.decode(result, (uint256));
    }

    function _historicalAddress(address target, bytes memory callData, string memory blockReference)
        internal
        returns (address value)
    {
        uint256 word = _historicalUint(target, callData, blockReference);
        require(word <= type(uint160).max, "invalid historical address result");
        // The word is range checked immediately above before narrowing.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(word));
    }

    function _historicalBool(address target, bytes memory callData, string memory blockReference)
        internal
        returns (bool value)
    {
        uint256 word = _historicalUint(target, callData, blockReference);
        require(word <= 1, "invalid historical bool result");
        value = word == 1;
    }

    function _historicalStringHash(address target, bytes memory callData, string memory blockReference)
        internal
        returns (bytes32)
    {
        bytes memory result = _historicalCall(target, callData, blockReference);
        require(result.length >= 64, "invalid historical string result");
        return keccak256(bytes(abi.decode(result, (string))));
    }
}
