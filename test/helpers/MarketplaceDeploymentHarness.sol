// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployMarketplaceRegistries} from "../../script/DeployMarketplaceRegistries.s.sol";
import {VerifyMarketplaceRegistries} from "../../script/VerifyMarketplaceRegistries.s.sol";
import {ReputationSafeSingletonStub, ThresholdSafeStub} from "./ReputationDeploymentHarness.sol";

/// @dev Both harnesses swap only the reviewed Safe identities for the local
///      stubs. The production chain gate of `reviewedSafeDeployment` still runs.
contract DeployMarketplaceRegistriesHarness is DeployMarketplaceRegistries {
    address private _reviewedSafeSingleton;
    address private _reviewedSafeHandler;

    function setReviewedSafeContracts(address singleton, address handler) external {
        _reviewedSafeSingleton = singleton;
        _reviewedSafeHandler = handler;
    }

    function reviewedSafeDeployment(uint256 chainId) public view override returns (bytes32, address, bytes32, address) {
        super.reviewedSafeDeployment(chainId);
        return (
            keccak256(type(ThresholdSafeStub).runtimeCode),
            _reviewedSafeSingleton,
            keccak256(type(ReputationSafeSingletonStub).runtimeCode),
            _reviewedSafeHandler
        );
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

    function reviewedSafeDeployment(uint256 chainId) public view override returns (bytes32, address, bytes32, address) {
        super.reviewedSafeDeployment(chainId);
        return (
            keccak256(type(ThresholdSafeStub).runtimeCode),
            _reviewedSafeSingleton,
            keccak256(type(ReputationSafeSingletonStub).runtimeCode),
            _reviewedSafeHandler
        );
    }

    function verify(Registries memory registries, address identityRegistry, address sanctionsOracle, address safe)
        external
        view
        returns (Registries memory)
    {
        return _verify(registries, identityRegistry, sanctionsOracle, safe);
    }
}
