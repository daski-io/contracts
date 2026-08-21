// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {StandardRailCircleUSDC} from "../script/StandardRailCircleUSDC.sol";
import {MockCircleUSDC} from "./mocks/MockCircleUSDC.sol";

contract StandardRailCircleUSDCHarness {
    function validate(address token, address splitter, address provider, address daski) external view {
        StandardRailCircleUSDC.validate(token, splitter, provider, daski);
    }
}

contract WrongDecimalsCircleUSDC is MockCircleUSDC {
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract OutcomeSplitterLivenessTest is Test {
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    MockCircleUSDC private token;
    MockCircleUSDC private tokenCodeSource;
    StandardRailCircleUSDCHarness private circleHarness;
    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");

    function setUp() public {
        vm.chainId(84_532);
        tokenCodeSource = new MockCircleUSDC();
        vm.etch(BASE_SEPOLIA_USDC, address(tokenCodeSource).code);
        token = MockCircleUSDC(BASE_SEPOLIA_USDC);
        circleHarness = new StandardRailCircleUSDCHarness();
    }

    function testCanonicalTokenAddressCodeAndDecimalsChecks() public {
        address splitter = makeAddr("splitter");
        circleHarness.validate(address(token), splitter, provider, daski);

        vm.chainId(1);
        vm.expectRevert(bytes("standard Testnet rail is Base Sepolia only"));
        circleHarness.validate(address(token), splitter, provider, daski);
        vm.chainId(84_532);

        vm.expectRevert(bytes("canonical token address mismatch"));
        circleHarness.validate(address(tokenCodeSource), splitter, provider, daski);

        vm.etch(address(token), bytes(""));
        vm.expectRevert(bytes("canonical token has no code"));
        circleHarness.validate(address(token), splitter, provider, daski);

        WrongDecimalsCircleUSDC wrongDecimals = new WrongDecimalsCircleUSDC();
        vm.etch(address(token), address(wrongDecimals).code);
        vm.expectRevert(bytes("canonical token decimals mismatch"));
        circleHarness.validate(address(token), splitter, provider, daski);
    }

    function testCircleReadinessRejectsPauseAndBlacklists() public {
        address splitter = makeAddr("splitter");
        token.setPaused(true);
        vm.expectRevert(bytes("canonical token is paused"));
        circleHarness.validate(address(token), splitter, provider, daski);

        token.setPaused(false);
        token.setBlacklisted(splitter, true);
        vm.expectRevert(bytes("splitter is blacklisted"));
        circleHarness.validate(address(token), splitter, provider, daski);

        token.setBlacklisted(splitter, false);
        token.setBlacklisted(provider, true);
        vm.expectRevert(bytes("provider is blacklisted"));
        circleHarness.validate(address(token), splitter, provider, daski);

        token.setBlacklisted(provider, false);
        token.setBlacklisted(daski, true);
        vm.expectRevert(bytes("Daski receiver is blacklisted"));
        circleHarness.validate(address(token), splitter, provider, daski);
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
