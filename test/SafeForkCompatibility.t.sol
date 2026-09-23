// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployMarketplaceRegistries} from "../script/DeployMarketplaceRegistries.s.sol";
import {DeployReputationStorage} from "../script/DeployReputationStorage.s.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract ForkMarketplaceGovernance is DeployMarketplaceRegistries {
    function validate(Config memory config) external view {
        _validateConfig(config);
    }
}

contract ForkReputationGovernance is DeployReputationStorage {
    function validate(DeploymentConfig memory config) external view {
        _validateGovernance(config);
    }
}

/// @dev Opt-in read-only observation of an existing Safe. Never broadcasts or signs.
contract SafeForkCompatibilityTest is Test {
    function testFork_existingSafePassesBothDeploymentPreflights() public {
        string memory rpc = vm.envOr("SAFE_VALIDATION_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        uint256 blockNumber = vm.envUint("SAFE_VALIDATION_BLOCK");
        address safe = vm.envAddress("SAFE_VALIDATION_ADDRESS");
        vm.createSelectFork(rpc, blockNumber);
        assertEq(block.chainid, 8453);
        address guardian = makeAddr("fork-only-guardian");
        DeployMarketplaceRegistries.Config memory registries = DeployMarketplaceRegistries.Config({
            identityRegistry: address(new MockCanonicalIdentityRegistry()),
            sanctionsOracle: address(new MockSanctionsList()),
            finalAdmin: safe,
            pauseGuardian: guardian,
            treasury: makeAddr("fork-only-treasury"),
            listingFee: 1000000
        });
        new ForkMarketplaceGovernance().validate(registries);
        DeployReputationStorage.DeploymentConfig memory reputation;
        reputation.admin = makeAddr("fork-only-bootstrap");
        reputation.finalAdmin = safe;
        reputation.pauseGuardian = guardian;
        reputation.orderSigner = makeAddr("fork-only-order-signer");
        new ForkReputationGovernance().validate(reputation);
    }
}
