// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployMarketplaceRegistries} from "../../script/DeployMarketplaceRegistries.s.sol";
import {VerifyMarketplaceRegistries} from "../../script/VerifyMarketplaceRegistries.s.sol";
import {
    ReputationSafeSingletonStub,
    ReputationSafeFallbackHandlerStub,
    ThresholdSafeStub
} from "./ReputationDeploymentHarness.sol";

/// @dev Both harnesses swap only the reviewed Safe identities for the local
///      stubs. The production chain gate of `reviewedSafeDeployment` still runs.
contract DeployMarketplaceRegistriesHarness is DeployMarketplaceRegistries {
    address private _reviewedSafeSingleton;
    address private _reviewedSafeHandler;

    function setReviewedSafeContracts(address singleton, address handler) external {
        _reviewedSafeSingleton = singleton;
        _reviewedSafeHandler = handler;
    }

    function reviewedSafeDeployment(uint256 chainId, bytes32 proxyCodeHash)
        public
        view
        override
        returns (SafeDeployment memory)
    {
        super.reviewedSafeDeployment(chainId, proxyCodeHash);
        return SafeDeployment({
            proxyCodeHash: keccak256(type(ThresholdSafeStub).runtimeCode),
            singleton: _reviewedSafeSingleton,
            singletonCodeHash: keccak256(type(ReputationSafeSingletonStub).runtimeCode),
            fallbackHandler: _reviewedSafeHandler,
            fallbackHandlerCodeHash: keccak256(type(ReputationSafeFallbackHandlerStub).runtimeCode)
        });
    }

    function deploy(Config memory config) external returns (Registries memory) {
        return _deploy(config);
    }

    function requireHandoffReady(Registries memory registries, Config memory config, address deployer) external view {
        _requireHandoffReady(registries, config, _validateConfig(config), deployer);
    }
}

contract VerifyMarketplaceRegistriesHarness is VerifyMarketplaceRegistries {
    address private _reviewedSafeSingleton;
    address private _reviewedSafeHandler;

    function setReviewedSafeContracts(address singleton, address handler) external {
        _reviewedSafeSingleton = singleton;
        _reviewedSafeHandler = handler;
    }

    function reviewedSafeDeployment(uint256 chainId, bytes32 proxyCodeHash)
        public
        view
        override
        returns (SafeDeployment memory)
    {
        super.reviewedSafeDeployment(chainId, proxyCodeHash);
        return SafeDeployment({
            proxyCodeHash: keccak256(type(ThresholdSafeStub).runtimeCode),
            singleton: _reviewedSafeSingleton,
            singletonCodeHash: keccak256(type(ReputationSafeSingletonStub).runtimeCode),
            fallbackHandler: _reviewedSafeHandler,
            fallbackHandlerCodeHash: keccak256(type(ReputationSafeFallbackHandlerStub).runtimeCode)
        });
    }

    function verify(Registries memory registries, address identityRegistry, address sanctionsOracle, address safe)
        external
        view
        returns (Registries memory)
    {
        return _verify(registries, identityRegistry, sanctionsOracle, safe);
    }
}
