// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {StandardRailCircleUSDC} from "../script/StandardRailCircleUSDC.sol";
import {MockCircleUSDC} from "./mocks/MockCircleUSDC.sol";

contract StandardRailCircleUSDCHarness {
    function validateIdentity(
        address token,
        uint256 chainId,
        address expectedToken,
        bytes32 proxyCodeHash,
        address implementation,
        bytes32 implementationCodeHash
    ) external view returns (address) {
        return StandardRailCircleUSDC.validateIdentity(
            token, chainId, expectedToken, proxyCodeHash, implementation, implementationCodeHash
        );
    }

    function validateBehavior(address token, address splitter, address provider, address daski) external view {
        StandardRailCircleUSDC.validateBehavior(token, splitter, provider, daski);
    }
}

contract WrongMetadataCircleUSDC is MockCircleUSDC {
    function name() public pure override returns (string memory) {
        return "USD Coin";
    }
}

contract OutcomeSplitterLivenessTest is Test {
    MockCircleUSDC private token;
    StandardRailCircleUSDCHarness private circleHarness;
    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");

    function setUp() public {
        vm.chainId(84_532);
        token = new MockCircleUSDC();
        circleHarness = new StandardRailCircleUSDCHarness();
    }

    function testCircleIdentityAndBehaviorChecks() public {
        assertEq(
            circleHarness.validateIdentity(
                address(token),
                block.chainid,
                address(token),
                address(token).codehash,
                address(token),
                address(token).codehash
            ),
            address(token)
        );
        circleHarness.validateBehavior(address(token), makeAddr("splitter"), provider, daski);
    }

    function testCircleIdentityRejectsUnexpectedCodeAndImplementation() public {
        vm.expectRevert(bytes("canonical token proxy code hash mismatch"));
        circleHarness.validateIdentity(
            address(token), block.chainid, address(token), bytes32(uint256(1)), address(token), address(token).codehash
        );

        vm.expectRevert(bytes("canonical token implementation mismatch"));
        circleHarness.validateIdentity(
            address(token),
            block.chainid,
            address(token),
            address(token).codehash,
            makeAddr("implementation"),
            bytes32(0)
        );

        vm.expectRevert(bytes("canonical token implementation code hash mismatch"));
        circleHarness.validateIdentity(
            address(token), block.chainid, address(token), address(token).codehash, address(token), bytes32(uint256(1))
        );
    }

    function testCircleReadinessRejectsMetadataAndMissingRoles() public {
        WrongMetadataCircleUSDC wrongMetadata = new WrongMetadataCircleUSDC();
        vm.expectRevert(bytes("canonical token name mismatch"));
        circleHarness.validateBehavior(address(wrongMetadata), makeAddr("splitter"), provider, daski);

        token.setPauser(address(0));
        vm.expectRevert(bytes("canonical token pauser missing"));
        circleHarness.validateBehavior(address(token), makeAddr("splitter"), provider, daski);

        token.setPauser(address(1));
        token.setBlacklister(address(0));
        vm.expectRevert(bytes("canonical token blacklister missing"));
        circleHarness.validateBehavior(address(token), makeAddr("splitter"), provider, daski);
    }

    function testCircleReadinessRejectsPauseAndBlacklists() public {
        address splitter = makeAddr("splitter");
        token.setPaused(true);
        vm.expectRevert(bytes("canonical token is paused"));
        circleHarness.validateBehavior(address(token), splitter, provider, daski);

        token.setPaused(false);
        token.setBlacklisted(splitter, true);
        vm.expectRevert(bytes("splitter is blacklisted"));
        circleHarness.validateBehavior(address(token), splitter, provider, daski);

        token.setBlacklisted(splitter, false);
        token.setBlacklisted(provider, true);
        vm.expectRevert(bytes("provider is blacklisted"));
        circleHarness.validateBehavior(address(token), splitter, provider, daski);

        token.setBlacklisted(provider, false);
        token.setBlacklisted(daski, true);
        vm.expectRevert(bytes("Daski receiver is blacklisted"));
        circleHarness.validateBehavior(address(token), splitter, provider, daski);
    }

    function testImmutableCircleControlsBlockReleaseWithoutChangingRoute() public {
        OutcomeSplitter splitter = _deploySplitter();
        token.mint(address(splitter), 1_000_000);

        token.setPaused(true);
        _expectBlockedRelease(splitter, "FiatToken: token is paused");
        token.setPaused(false);

        token.setBlacklisted(address(splitter), true);
        _expectBlockedRelease(splitter, "FiatToken: account is blacklisted");
        token.setBlacklisted(address(splitter), false);

        token.setBlacklisted(provider, true);
        _expectBlockedRelease(splitter, "FiatToken: account is blacklisted");
        token.setBlacklisted(provider, false);

        token.setBlacklisted(daski, true);
        _expectBlockedRelease(splitter, "FiatToken: account is blacklisted");
        token.setBlacklisted(daski, false);

        assertEq(splitter.providerPayee(), provider);
        assertEq(splitter.daskiCommissionReceiver(), daski);
        splitter.releaseAll();
        assertEq(token.balanceOf(provider), 950_000);
        assertEq(token.balanceOf(daski), 50_000);
    }

    function testForcedNativeCurrencyRemainsOutsideTokenAccounting() public {
        OutcomeSplitter splitter = _deploySplitter();
        // Models native currency delivered without executing receive or fallback.
        vm.deal(address(splitter), 1 ether);
        token.mint(address(splitter), 1_000_000);

        splitter.releaseAll();

        assertEq(address(splitter).balance, 1 ether);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(provider), 950_000);
        assertEq(token.balanceOf(daski), 50_000);
    }

    function _expectBlockedRelease(OutcomeSplitter splitter, string memory reason) private {
        vm.expectRevert(bytes(reason));
        splitter.releaseAll();
        assertEq(token.balanceOf(address(splitter)), 1_000_000);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(daski), 0);
    }

    function _deploySplitter() private returns (OutcomeSplitter) {
        return new OutcomeSplitter(
            block.chainid,
            address(token),
            provider,
            daski,
            500,
            keccak256("policy"),
            keccak256("outcome"),
            keccak256("listing"),
            1
        );
    }
}
