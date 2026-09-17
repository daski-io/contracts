// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeSplitter} from "../src/OutcomeSplitter.sol";
import {OutcomeSplitterFactory} from "../src/OutcomeSplitterFactory.sol";
import {OutcomeSplitterCreate2} from "../src/utils/OutcomeSplitterCreate2.sol";
import {DeployOutcomeSplitter} from "../script/DeployOutcomeSplitter.s.sol";
import {DeployOutcomeSplitterFactory} from "../script/DeployOutcomeSplitterFactory.s.sol";
import {MockCircleUSDC} from "./mocks/MockCircleUSDC.sol";

contract DeployOutcomeSplitterHarness is DeployOutcomeSplitter {
    function deploy(SplitterInput memory input) external returns (address) {
        return _deploy(input);
    }
}

contract OutcomeSplitterDeploymentScriptsTest is Test {
    uint256 private constant BASE_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes private constant UNSUPPORTED_CHAIN = "standard rail supports Base and Base Sepolia only";
    string private constant FACTORY_RUNTIME_CODE_HASH_ENV = "STANDARD_RAIL_SPLITTER_FACTORY_RUNTIME_CODE_HASH";

    DeployOutcomeSplitterFactory private factoryScript;
    DeployOutcomeSplitterHarness private splitterScript;
    OutcomeSplitterFactory private factory;

    address private provider = makeAddr("provider");
    address private daski = makeAddr("daski");
    bytes32 private policyHash = keccak256("policy");
    bytes32 private outcomeHash = keccak256("outcome");
    bytes32 private listingHash = keccak256("listing");
    bytes32 private salt = keccak256("salt");

    function setUp() public {
        factoryScript = new DeployOutcomeSplitterFactory();
        splitterScript = new DeployOutcomeSplitterHarness();
        factory = new OutcomeSplitterFactory();

        MockCircleUSDC tokenCodeSource = new MockCircleUSDC();
        vm.etch(BASE_USDC, address(tokenCodeSource).code);
        vm.etch(BASE_SEPOLIA_USDC, address(tokenCodeSource).code);
        // Every test that reads this variable sets the same build-derived value.
        _setEnv(FACTORY_RUNTIME_CODE_HASH_ENV, vm.toString(factoryScript.compiledFactoryRuntimeCodeHash()));
    }

    function testFactoryScriptDeploysReviewedFactoryOnBothChainsOnly() public {
        bytes32 reviewedHash = factoryScript.compiledFactoryRuntimeCodeHash();

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        assertEq(address(factoryScript.run()).codehash, reviewedHash);

        vm.chainId(BASE_CHAIN_ID);
        assertEq(address(factoryScript.run()).codehash, reviewedHash);

        uint256[3] memory unsupported = [uint256(1), 31_337, 11_155_111];
        for (uint256 i = 0; i < unsupported.length; i++) {
            vm.chainId(unsupported[i]);
            vm.expectRevert(UNSUPPORTED_CHAIN);
            factoryScript.run();
        }
    }

    function testSplitterScriptBindsBaseSepoliaAndItsReviewedToken() public {
        _checkSplitterBoundToChainAndReviewedToken(BASE_SEPOLIA_CHAIN_ID, BASE_SEPOLIA_USDC);
    }

    function testSplitterScriptBindsBaseAndItsReviewedToken() public {
        _checkSplitterBoundToChainAndReviewedToken(BASE_CHAIN_ID, BASE_USDC);
    }

    function testSplitterScriptRefusesUnsupportedChain() public {
        uint256[3] memory unsupported = [uint256(1), 31_337, 11_155_111];
        for (uint256 i = 0; i < unsupported.length; i++) {
            vm.chainId(unsupported[i]);
            DeployOutcomeSplitter.SplitterInput memory input = _input(unsupported[i], BASE_USDC);
            vm.expectRevert(UNSUPPORTED_CHAIN);
            splitterScript.deploy(input);
        }
    }

    function testSplitterScriptRefusesReviewForAnotherChainOrToken() public {
        vm.chainId(BASE_CHAIN_ID);

        // Reviewed for Base Sepolia, executed on Base.
        DeployOutcomeSplitter.SplitterInput memory input = _input(BASE_SEPOLIA_CHAIN_ID, BASE_SEPOLIA_USDC);
        vm.expectRevert(bytes("splitter init code hash mismatch"));
        splitterScript.deploy(input);

        // Reviewed for the executing chain, but with a token other than its reviewed one.
        address[2] memory wrongTokens = [BASE_SEPOLIA_USDC, address(new MockCircleUSDC())];
        for (uint256 i = 0; i < wrongTokens.length; i++) {
            input = _input(BASE_CHAIN_ID, wrongTokens[i]);
            vm.expectRevert(bytes("splitter init code hash mismatch"));
            splitterScript.deploy(input);
        }

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        input = _input(BASE_SEPOLIA_CHAIN_ID, BASE_USDC);
        vm.expectRevert(bytes("splitter init code hash mismatch"));
        splitterScript.deploy(input);
    }

    function testSplitterScriptKeepsInputRangeAndProvenanceChecks() public {
        vm.chainId(BASE_CHAIN_ID);

        DeployOutcomeSplitter.SplitterInput memory input = _input(BASE_CHAIN_ID, BASE_USDC);
        input.commissionBps = 10_000;
        vm.expectRevert(bytes("invalid commission bps"));
        splitterScript.deploy(input);

        input = _input(BASE_CHAIN_ID, BASE_USDC);
        input.listingEpoch = uint256(type(uint64).max) + 1;
        vm.expectRevert(bytes("invalid listing epoch"));
        splitterScript.deploy(input);

        input = _input(BASE_CHAIN_ID, BASE_USDC);
        input.factory = OutcomeSplitterFactory(address(new MockCircleUSDC()));
        vm.expectRevert(bytes("factory runtime code hash mismatch"));
        splitterScript.deploy(input);

        input = _input(BASE_CHAIN_ID, BASE_USDC);
        input.creationCodeHash = bytes32(uint256(input.creationCodeHash) ^ 1);
        vm.expectRevert(bytes("splitter creation code hash mismatch"));
        splitterScript.deploy(input);
    }

    function testSplitterScriptRunReadsReviewedInputsFromEnvironment() public {
        vm.chainId(BASE_CHAIN_ID);
        DeployOutcomeSplitter.SplitterInput memory input = _input(BASE_CHAIN_ID, BASE_USDC);
        // No other test reads or writes these variables, so parallel tests cannot interfere.
        _setEnv("STANDARD_RAIL_SPLITTER_FACTORY", vm.toString(address(input.factory)));
        _setEnv("STANDARD_RAIL_PROVIDER_PAYEE", vm.toString(input.provider));
        _setEnv("STANDARD_RAIL_DASKI_COMMISSION_RECEIVER", vm.toString(input.daski));
        _setEnv("MARKETPLACE_COMMISSION_BPS", vm.toString(input.commissionBps));
        _setEnv("STANDARD_RAIL_POLICY_VERSION_HASH", vm.toString(input.policyHash));
        _setEnv("STANDARD_RAIL_OUTCOME_ID_HASH", vm.toString(input.outcomeHash));
        _setEnv("STANDARD_RAIL_LISTING_COMMITMENT_HASH", vm.toString(input.listingHash));
        _setEnv("STANDARD_RAIL_LISTING_EPOCH", vm.toString(input.listingEpoch));
        _setEnv("STANDARD_RAIL_DEPLOYMENT_SALT", vm.toString(input.salt));
        _setEnv("STANDARD_RAIL_SPLITTER_CREATION_CODE_HASH", vm.toString(input.creationCodeHash));
        _setEnv("STANDARD_RAIL_SPLITTER_INIT_CODE_HASH", vm.toString(input.initCodeHash));

        OutcomeSplitter splitter = OutcomeSplitter(payable(splitterScript.run()));

        assertEq(splitter.canonicalChainId(), BASE_CHAIN_ID);
        assertEq(splitter.canonicalToken(), BASE_USDC);
        assertEq(splitter.providerPayee(), provider);
        assertEq(splitter.daskiCommissionReceiver(), daski);
    }

    function _checkSplitterBoundToChainAndReviewedToken(uint256 chainId, address reviewedToken) private {
        vm.chainId(chainId);
        DeployOutcomeSplitter.SplitterInput memory input = _input(chainId, reviewedToken);

        OutcomeSplitter splitter = OutcomeSplitter(payable(splitterScript.deploy(input)));

        assertEq(
            address(splitter),
            factory.computeAddress(
                salt, chainId, reviewedToken, provider, daski, 500, policyHash, outcomeHash, listingHash, 1
            )
        );
        assertEq(splitter.canonicalChainId(), chainId);
        assertEq(splitter.canonicalToken(), reviewedToken);
        assertEq(splitter.providerPayee(), provider);
        assertEq(splitter.daskiCommissionReceiver(), daski);
        assertEq(splitter.commissionBps(), 500);
        assertEq(splitter.policyVersionHash(), policyHash);
        assertEq(splitter.outcomeIdHash(), outcomeHash);
        assertEq(splitter.listingCommitmentHash(), listingHash);
        assertEq(splitter.listingEpoch(), 1);
    }

    function _setEnv(string memory name, string memory value) private {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(name, value);
    }

    /// @dev Inputs as a reviewer would prepare them for `reviewedChainId` and `reviewedToken`.
    function _input(uint256 reviewedChainId, address reviewedToken)
        private
        view
        returns (DeployOutcomeSplitter.SplitterInput memory input)
    {
        input.factory = factory;
        input.provider = provider;
        input.daski = daski;
        input.commissionBps = 500;
        input.policyHash = policyHash;
        input.outcomeHash = outcomeHash;
        input.listingHash = listingHash;
        input.listingEpoch = 1;
        input.salt = salt;
        input.factoryRuntimeCodeHash = factoryScript.compiledFactoryRuntimeCodeHash();
        input.creationCodeHash = OutcomeSplitterCreate2.creationCodeHash();
        input.initCodeHash = OutcomeSplitterCreate2.initCodeHash(
            reviewedChainId, reviewedToken, provider, daski, 500, policyHash, outcomeHash, listingHash, 1
        );
    }
}
