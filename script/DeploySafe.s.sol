// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SafeDeployment, ISafe, ISafeProxyFactory} from "./SafeDeployment.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";

/// @notice Deploys the governance Safe that Deploy.s.sol requires as
///         ADMIN_ADDRESS, via the canonical Safe v1.4.1 proxy factory.
///
///         Developer testnet deployments may use the 1-of-1 default.
///         Mainnet and release-candidate rehearsals refuse that profile.
///
///         SAFE_OWNERS      comma-separated owner addresses (default: deployer)
///         SAFE_THRESHOLD   confirmation threshold (default: 1)
///         SAFE_SALT_NONCE  create2 salt; same owners+threshold+salt is the
///                          same address, so redeploying requires a new salt
///                          (default: 0)
contract DeploySafe is Script {
    function run() external returns (address safe) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address[] memory defaultOwners = new address[](1);
        defaultOwners[0] = deployer;
        address[] memory owners = vm.envOr("SAFE_OWNERS", ",", defaultOwners);
        uint256 threshold = vm.envOr("SAFE_THRESHOLD", uint256(1));
        uint256 saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(0));
        bool releaseCandidate = vm.envOr("RELEASE_CANDIDATE", false);

        SafeDeployment.validateCanonicalDeployment();
        if (block.chainid == DeploymentValidation.BASE_MAINNET || releaseCandidate) {
            require(
                owners.length >= 2 && threshold >= 2,
                "release governance Safe must be a real multisig (>=2 owners, threshold >=2)"
            );
        }
        bytes memory initializer = SafeDeployment.setupInitializer(owners, threshold);

        vm.startBroadcast(deployerKey);
        safe = ISafeProxyFactory(SafeDeployment.SAFE_PROXY_FACTORY)
            .createProxyWithNonce(SafeDeployment.SAFE_L2_SINGLETON, initializer, saltNonce);
        vm.stopBroadcast();

        address[] memory noModules = new address[](0);
        SafeDeployment.validateSafeProfile(
            safe,
            SafeDeployment.Profile({
                owners: owners,
                threshold: threshold,
                modules: noModules,
                guard: address(0),
                fallbackHandler: SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER,
                releaseCandidate: releaseCandidate
            })
        );

        address[] memory liveOwners = ISafe(safe).getOwners();

        console.log("Governance Safe (v1.4.1, SafeL2):", safe);
        console.log("  owners:", liveOwners.length);
        for (uint256 i = 0; i < liveOwners.length; i++) {
            console.log("   ", liveOwners[i]);
        }
        console.log("  threshold:", threshold);
        if (threshold == 1) {
            console.log("  NOTE: 1-of-1 Safe = test-grade governance, never acceptable on mainnet");
        }
        console.log("Use as the deployment admin:");
        console.log("  export ADMIN_ADDRESS=", safe);
    }
}
