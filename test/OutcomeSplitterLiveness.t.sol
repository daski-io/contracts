// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {StandardRailCircleUSDC} from "../script/StandardRailCircleUSDC.sol";
import {MockCircleUSDC} from "./mocks/MockCircleUSDC.sol";

contract StandardRailCircleUSDCHarness {
    function requireSupportedChain(uint256 chainId) external pure {
        StandardRailCircleUSDC.requireSupportedChain(chainId);
    }

    function canonicalToken(uint256 chainId) external pure returns (address) {
        return StandardRailCircleUSDC.canonicalToken(chainId);
    }

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
    uint256 private constant BASE_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes private constant UNSUPPORTED_CHAIN = "standard rail supports Base and Base Sepolia only";

    MockCircleUSDC private token;
    MockCircleUSDC private tokenCodeSource;
    StandardRailCircleUSDCHarness private circleHarness;
    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");

    function setUp() public {
        tokenCodeSource = new MockCircleUSDC();
        circleHarness = new StandardRailCircleUSDCHarness();
        _selectChain(BASE_SEPOLIA_CHAIN_ID);
    }

    function testReviewedTokenIsFixedPerSupportedChain() public {
        assertEq(circleHarness.canonicalToken(BASE_CHAIN_ID), BASE_USDC);
        assertEq(circleHarness.canonicalToken(BASE_SEPOLIA_CHAIN_ID), BASE_SEPOLIA_USDC);
        circleHarness.requireSupportedChain(BASE_CHAIN_ID);
        circleHarness.requireSupportedChain(BASE_SEPOLIA_CHAIN_ID);

        uint256[4] memory unsupported = [uint256(0), 1, 31_337, 11_155_111];
        for (uint256 i = 0; i < unsupported.length; i++) {
            vm.expectRevert(UNSUPPORTED_CHAIN);
            circleHarness.requireSupportedChain(unsupported[i]);
            vm.expectRevert(UNSUPPORTED_CHAIN);
            circleHarness.canonicalToken(unsupported[i]);
        }
    }

    function testCanonicalTokenAddressCodeAndDecimalsChecksOnBaseSepolia() public {
        _checkCanonicalTokenAddressCodeAndDecimals(BASE_SEPOLIA_CHAIN_ID);
    }

    function testCanonicalTokenAddressCodeAndDecimalsChecksOnBase() public {
        _checkCanonicalTokenAddressCodeAndDecimals(BASE_CHAIN_ID);
    }

    function testReviewedTokenOfTheOtherChainIsRefused() public {
        address splitter = makeAddr("splitter");
        vm.etch(BASE_USDC, address(tokenCodeSource).code);
        vm.etch(BASE_SEPOLIA_USDC, address(tokenCodeSource).code);

        vm.chainId(BASE_CHAIN_ID);
        circleHarness.validate(BASE_USDC, splitter, provider, daski);
        vm.expectRevert(bytes("canonical token address mismatch"));
        circleHarness.validate(BASE_SEPOLIA_USDC, splitter, provider, daski);

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        circleHarness.validate(BASE_SEPOLIA_USDC, splitter, provider, daski);
        vm.expectRevert(bytes("canonical token address mismatch"));
        circleHarness.validate(BASE_USDC, splitter, provider, daski);
    }

    function testUnsupportedChainIsRefusedForEveryToken() public {
        address splitter = makeAddr("splitter");
        vm.etch(BASE_USDC, address(tokenCodeSource).code);
        vm.etch(BASE_SEPOLIA_USDC, address(tokenCodeSource).code);

        uint256[3] memory unsupported = [uint256(1), 31_337, 11_155_111];
        for (uint256 i = 0; i < unsupported.length; i++) {
            vm.chainId(unsupported[i]);
            vm.expectRevert(UNSUPPORTED_CHAIN);
            circleHarness.validate(BASE_USDC, splitter, provider, daski);
            vm.expectRevert(UNSUPPORTED_CHAIN);
            circleHarness.validate(BASE_SEPOLIA_USDC, splitter, provider, daski);
            vm.expectRevert(UNSUPPORTED_CHAIN);
            circleHarness.validate(address(tokenCodeSource), splitter, provider, daski);
        }
    }

    function testCircleReadinessRejectsPauseAndBlacklistsOnBaseSepolia() public {
        _checkCircleReadinessRejectsPauseAndBlacklists(BASE_SEPOLIA_CHAIN_ID);
    }

    function testCircleReadinessRejectsPauseAndBlacklistsOnBase() public {
        _checkCircleReadinessRejectsPauseAndBlacklists(BASE_CHAIN_ID);
    }

    function _checkCanonicalTokenAddressCodeAndDecimals(uint256 chainId) private {
        _selectChain(chainId);
        address splitter = makeAddr("splitter");
        circleHarness.validate(address(token), splitter, provider, daski);

        vm.chainId(1);
        vm.expectRevert(UNSUPPORTED_CHAIN);
        circleHarness.validate(address(token), splitter, provider, daski);
        vm.chainId(chainId);

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

    function _checkCircleReadinessRejectsPauseAndBlacklists(uint256 chainId) private {
        _selectChain(chainId);
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

    /// @dev Installs the Circle-style test token at the reviewed address of `chainId`.
    function _selectChain(uint256 chainId) private {
        vm.chainId(chainId);
        address reviewed = chainId == BASE_CHAIN_ID ? BASE_USDC : BASE_SEPOLIA_USDC;
        vm.etch(reviewed, address(tokenCodeSource).code);
        token = MockCircleUSDC(reviewed);
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
