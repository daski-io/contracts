// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract OutcomeSplitterTest is Test {
    MockUSDC private token;
    OutcomeSplitterFactory private factory;
    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");
    bytes32 private policyHash = keccak256("policy");
    bytes32 private outcomeHash = keccak256("outcome");
    bytes32 private listingHash = keccak256("listing");

    function setUp() public {
        vm.chainId(84532);
        token = new MockUSDC();
        factory = new OutcomeSplitterFactory();
    }

    function testDeterministicDeploymentAndImmutableRoute() public {
        bytes32 salt = keccak256("salt");
        address predicted = factory.computeAddress(
            salt, block.chainid, address(token), provider, daski, 750, policyHash, outcomeHash, listingHash, 4
        );
        address deployed = factory.deploy(
            salt, block.chainid, address(token), provider, daski, 750, policyHash, outcomeHash, listingHash, 4
        );

        assertEq(deployed, predicted);
        OutcomeSplitter splitter = OutcomeSplitter(payable(deployed));
        assertEq(splitter.canonicalChainId(), block.chainid);
        assertEq(splitter.canonicalToken(), address(token));
        assertEq(splitter.providerPayee(), provider);
        assertEq(splitter.daskiCommissionReceiver(), daski);
        assertEq(splitter.commissionBps(), 750);
        assertEq(splitter.policyVersionHash(), policyHash);
        assertEq(splitter.outcomeIdHash(), outcomeHash);
        assertEq(splitter.listingCommitmentHash(), listingHash);
        assertEq(splitter.listingEpoch(), 4);
    }

    function testPermissionlessWholeBalanceRelease() public {
        OutcomeSplitter splitter = _deploy(1_000);
        token.mint(address(splitter), 10_000_001);

        vm.prank(makeAddr("anyone"));
        uint256 gross = splitter.releaseAll();

        assertEq(gross, 10_000_001);
        assertEq(token.balanceOf(provider), 9_000_001);
        assertEq(token.balanceOf(daski), 1_000_000);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(splitter.releaseSequence(), 1);
    }

    function testDirectDonationsUseTheOnlyRoute() public {
        OutcomeSplitter splitter = _deploy(500);
        token.mint(address(splitter), 1_000_000);
        token.mint(address(splitter), 2_000_000);

        splitter.releaseAll();

        assertEq(token.balanceOf(provider), 2_850_000);
        assertEq(token.balanceOf(daski), 150_000);
    }

    function testFuzzReleaseConservesBalance(uint256 amount, uint16 bps) public {
        bps = uint16(bound(bps, 1, 9_999));
        OutcomeSplitter splitter = _deploy(bps);
        uint256 minimum = splitter.minimumReleasableBalance();
        amount = bound(amount, minimum, type(uint256).max);
        token.mint(address(splitter), amount);

        splitter.releaseAll();

        uint256 commission = amount / 10_000 * bps + (amount % 10_000) * bps / 10_000;
        assertEq(token.balanceOf(daski), commission);
        assertEq(token.balanceOf(provider), amount - commission);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function testFullPrecisionCommissionDoesNotOverflow() public {
        OutcomeSplitter splitter = _deploy(9_999);
        token.mint(address(splitter), type(uint256).max);

        splitter.releaseAll();

        uint256 commission = type(uint256).max / 10_000 * 9_999 + (type(uint256).max % 10_000) * 9_999 / 10_000;
        assertEq(token.balanceOf(daski), commission);
        assertEq(token.balanceOf(provider), type(uint256).max - commission);
    }

    function testFeeOnTransferRevertsBothPayoutLegs() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        OutcomeSplitter splitter = _deployWithToken(address(feeToken), 500);
        feeToken.mint(address(splitter), 1_000_000);

        vm.expectRevert(OutcomeSplitter.UnexpectedTokenDelta.selector);
        splitter.releaseAll();

        assertEq(feeToken.balanceOf(provider), 0);
        assertEq(feeToken.balanceOf(daski), 0);
        assertEq(feeToken.balanceOf(address(splitter)), 1_000_000);
    }

    function testReentrantTokenCannotEnterReleaseTwice() public {
        ReentrantToken reentrantToken = new ReentrantToken();
        OutcomeSplitter splitter = _deployWithToken(address(reentrantToken), 500);
        reentrantToken.setTarget(address(splitter));
        reentrantToken.mint(address(splitter), 1_000_000);

        splitter.releaseAll();

        assertTrue(reentrantToken.reentryAttempted());
        assertFalse(reentrantToken.reentrySucceeded());
        assertEq(reentrantToken.balanceOf(provider), 950_000);
        assertEq(reentrantToken.balanceOf(daski), 50_000);
        assertEq(splitter.releaseSequence(), 1);
    }

    function testRepeatedReleaseNeedsNewBalance() public {
        OutcomeSplitter splitter = _deploy(500);
        token.mint(address(splitter), 1_000_000);
        splitter.releaseAll();

        vm.expectRevert(abi.encodeWithSelector(OutcomeSplitter.BalanceBelowMinimum.selector, 0, 20));
        splitter.releaseAll();

        token.mint(address(splitter), 1_000_000);
        splitter.releaseAll();
        assertEq(splitter.releaseSequence(), 2);
    }

    function testRejectsSubMinimumDust() public {
        OutcomeSplitter splitter = _deploy(500);
        token.mint(address(splitter), 19);

        vm.expectRevert(abi.encodeWithSelector(OutcomeSplitter.BalanceBelowMinimum.selector, 19, 20));
        splitter.releaseAll();
    }

    function testRejectsNativeCurrency() public {
        OutcomeSplitter splitter = _deploy(500);
        vm.deal(address(this), 1 ether);

        (bool ok, bytes memory reason) = address(splitter).call{value: 1}("");
        assertFalse(ok);
        assertEq(keccak256(reason), keccak256(abi.encodeWithSelector(OutcomeSplitter.NativeCurrencyRejected.selector)));
    }

    function testRejectsInvalidConstructorAuthority() public {
        vm.expectRevert(OutcomeSplitter.InvalidRecipient.selector);
        new OutcomeSplitter(
            block.chainid, address(token), provider, provider, 500, policyHash, outcomeHash, listingHash, 1
        );

        vm.expectRevert(OutcomeSplitter.InvalidCommission.selector);
        new OutcomeSplitter(block.chainid, address(token), provider, daski, 0, policyHash, outcomeHash, listingHash, 1);

        vm.expectRevert(OutcomeSplitter.InvalidListing.selector);
        new OutcomeSplitter(block.chainid, address(token), provider, daski, 500, policyHash, outcomeHash, bytes32(0), 1);

        vm.expectRevert(OutcomeSplitter.InvalidToken.selector);
        new OutcomeSplitter(
            block.chainid, makeAddr("not-a-token"), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );

        vm.expectRevert(OutcomeSplitter.InvalidRecipient.selector);
        new OutcomeSplitter(
            block.chainid, address(token), address(token), daski, 500, policyHash, outcomeHash, listingHash, 1
        );
    }

    function testRejectsMismatchedChain() public {
        vm.expectRevert(OutcomeSplitter.InvalidChain.selector);
        new OutcomeSplitter(
            block.chainid + 1, address(token), provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );
    }

    function _deploy(uint16 bps) private returns (OutcomeSplitter) {
        return _deployWithToken(address(token), bps);
    }

    function _deployWithToken(address tokenAddress, uint16 bps) private returns (OutcomeSplitter) {
        return
            new OutcomeSplitter(
                block.chainid, tokenAddress, provider, daski, bps, policyHash, outcomeHash, listingHash, 1
            );
    }
}
