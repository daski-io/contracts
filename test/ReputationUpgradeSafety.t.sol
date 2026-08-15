// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationStorageUpgradeProbe is ReputationStorage {
    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("reputation-storage-upgrade-probe");
    }
}

contract ReputationUpgradeSafetyTest is ReputationTestBase {
    function test_upgradePreservesConfigurationRecordsAndAccounting() public {
        bytes32 orderKey = keccak256("upgrade-order");
        ReputationStorageBase.StandardReputationOrderV1 memory permit = _permit(orderKey);
        _register(permit);
        ReputationStorageUpgradeProbe implementation = new ReputationStorageUpgradeProbe();

        vm.prank(makeAddr("not-admin"));
        vm.expectRevert("not admin");
        reputation.upgradeToAndCall(address(implementation), "");

        vm.prank(admin);
        reputation.upgradeToAndCall(address(implementation), "");
        ReputationStorageUpgradeProbe upgraded = ReputationStorageUpgradeProbe(address(reputation));
        assertEq(upgraded.upgradeProbe(), keccak256("reputation-storage-upgrade-probe"));
        assertTrue(upgraded.isConfigured());
        assertEq(upgraded.admin(), admin);
        assertEq(upgraded.orderSigner(), vm.addr(ORDER_SIGNER_KEY));
        assertEq(upgraded.getRecord(orderKey).authorizationKey, permit.authorizationKey);
        (,,,,, uint256 count) = upgraded.getProviderStats(PROVIDER_AGENT_ID);
        assertEq(count, 1);
    }
}
