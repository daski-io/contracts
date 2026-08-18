// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StandardRailCircleUSDC} from "../script/StandardRailCircleUSDC.sol";
import {MockCircleUSDC} from "./mocks/MockCircleUSDC.sol";

contract StandardRailCircleSnapshotHarness {
    function validateIdentity(
        uint256 chainId,
        address token,
        StandardRailCircleUSDC.Snapshot memory snapshot,
        uint256 expectedChainId,
        address expectedToken,
        bytes32 expectedProxyCodeHash,
        address expectedImplementation,
        bytes32 expectedImplementationCodeHash
    ) external pure {
        StandardRailCircleUSDC.validateSnapshotIdentity(
            chainId,
            token,
            snapshot,
            expectedChainId,
            expectedToken,
            expectedProxyCodeHash,
            expectedImplementation,
            expectedImplementationCodeHash
        );
    }

    function validateBehavior(StandardRailCircleUSDC.Snapshot memory snapshot) external pure {
        StandardRailCircleUSDC.validateSnapshotBehavior(snapshot);
    }
}

contract OutcomeSplitterActivationSnapshotTest is Test {
    MockCircleUSDC private token;
    StandardRailCircleSnapshotHarness private harness;

    function setUp() public {
        vm.chainId(84_532);
        token = new MockCircleUSDC();
        harness = new StandardRailCircleSnapshotHarness();
    }

    function testBackdatedUnhealthySnapshotFailsEvenWhenHeadIsHealthy() public {
        StandardRailCircleUSDC.Snapshot memory activation = _snapshot();
        activation.paused = true;
        assertFalse(token.paused(), "head remains healthy");

        vm.expectRevert(bytes("canonical token is paused"));
        harness.validateBehavior(activation);
    }

    function testHealthyActivationSnapshotDoesNotDependOnLaterHeadPause() public {
        StandardRailCircleUSDC.Snapshot memory activation = _snapshot();
        token.setPaused(true);
        assertTrue(token.paused(), "head changed after activation");

        harness.validateBehavior(activation);
    }

    function testBackdatedIdentityMismatchFailsEvenWhenHeadIdentityMatches() public {
        StandardRailCircleUSDC.Snapshot memory activation = _snapshot();
        activation.implementation = makeAddr("wrong-activation-implementation");
        assertEq(token.implementation(), address(token), "head identity remains reviewed");

        vm.expectRevert(bytes("canonical token implementation mismatch"));
        harness.validateIdentity(
            block.chainid,
            address(token),
            activation,
            block.chainid,
            address(token),
            address(token).codehash,
            address(token),
            address(token).codehash
        );
    }

    function _snapshot() private view returns (StandardRailCircleUSDC.Snapshot memory snapshot) {
        snapshot.proxyCodeHash = address(token).codehash;
        snapshot.implementation = token.implementation();
        snapshot.implementationCodeHash = snapshot.implementation.codehash;
        snapshot.nameHash = keccak256(bytes(token.name()));
        snapshot.symbolHash = keccak256(bytes(token.symbol()));
        snapshot.currencyHash = keccak256(bytes(token.currency()));
        snapshot.decimals = token.decimals();
        snapshot.versionHash = keccak256(bytes(token.version()));
        snapshot.pauser = token.pauser();
        snapshot.blacklister = token.blacklister();
        snapshot.paused = token.paused();
    }
}
