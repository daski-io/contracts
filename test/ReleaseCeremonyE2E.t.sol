// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExecuteGovernanceBatches} from "../script/ExecuteGovernanceBatches.s.sol";
import {VerifyDeployment} from "../script/VerifyDeployment.s.sol";
import {ReleaseManifest} from "../script/ReleaseManifest.sol";
import {DeploymentValidation} from "../script/DeploymentValidation.sol";
import {SafeDeployment, ISafe} from "../script/SafeDeployment.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {ReleaseCeremonyManifestBuilder} from "./helpers/ReleaseCeremonyManifest.sol";

contract ReleaseCeremonyExecutionHarness is ExecuteGovernanceBatches {
    function _validateCanonicalSafeDeployment() internal pure override {}

    function _executeBatch(RunContext memory, address safe, address[] memory targets, bytes[] memory calls)
        internal
        override
    {
        for (uint256 i = 0; i < targets.length; i++) {
            vm.prank(safe);
            (bool success, bytes memory result) = targets[i].call(calls[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }
}

contract ReleaseCeremonyPendingHarness is ReleaseManifest {
    function verifyDarkPending(address deployer) external view {
        Manifest memory manifest = _loadManifest();
        _validateManifestCore(manifest);
        DeploymentValidation.validateDarkState(manifest.stack);
        DeploymentValidation.validatePendingAdmins(
            DeploymentValidation.adminContracts(manifest.stack),
            deployer,
            manifest.admin,
            manifest.governance,
            manifest.localFixture
        );
    }
}

contract ReleaseCeremonyE2ETest is ReleaseCeremonyManifestBuilder {
    bytes internal constant SAFE_PROXY_RUNTIME =
        hex"608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033";

    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    address private deployer;
    address private safe;
    address private guardian;
    address private initialFacilitator;
    CeremonyFixture private fixture;
    ReleaseCeremonyExecutionHarness private executor;
    ReleaseCeremonyPendingHarness private pendingVerifier;
    VerifyDeployment private verifier;
    string private evidenceRoot;
    string private manifestPath;
    string private revisionPath;
    string private provenancePath;

    function setUp() public {
        require(block.chainid == 31337, "release ceremony E2E requires local Anvil chain 31337");
        deployer = vm.addr(DEPLOYER_KEY);
        safe = makeAddr("ceremonySafe");
        guardian = makeAddr("ceremonyGuardian");
        initialFacilitator = makeAddr("initialFacilitator");
        evidenceRoot = vm.envOr("E2E_EVIDENCE_DIR", string("/tmp/daski-release-e2e"));
        string memory buildProfilePath =
            vm.envOr("E2E_BUILD_PROFILE_PATH", string("test/vectors/release-build-profile.json"));
        vm.createDir(evidenceRoot, true);
        manifestPath = string.concat(evidenceRoot, "/working-manifest.json");
        revisionPath = string.concat(evidenceRoot, "/working-revision-evidence.json");
        provenancePath = string.concat(evidenceRoot, "/working-provenance.json");

        _mockSafeProfile();
        fixture = _deployCeremonyStack(deployer, safe, guardian, initialFacilitator);
        _writeManifest(fixture, buildProfilePath, manifestPath, deployer, safe, guardian, initialFacilitator);
        address[] memory facilitators = new address[](1);
        facilitators[0] = initialFacilitator;
        _writeReleaseInputs(manifestPath, revisionPath, provenancePath, facilitators, new bytes32[](0));

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("GOVERNANCE_SENDER", vm.toString(deployer));
        executor = new ReleaseCeremonyExecutionHarness();
        pendingVerifier = new ReleaseCeremonyPendingHarness();
        verifier = new VerifyDeployment();
    }

    function test_cleanCloneReleaseCeremony() public {
        pendingVerifier.verifyDarkPending(deployer);

        _emitThenExecute("accept");
        _verify(false, false);
        _emitThenExecute("guardian");
        _verify(false, false);
        _emitThenExecute("activate");
        _verify(true, false);
        _emitThenExecute("pause");
        _verify(true, true);
        _emitThenExecute("unpause");
        _verify(true, false);

        address finalFacilitator = makeAddr("finalFacilitator");
        vm.startPrank(safe);
        X402Adapter(fixture.stack.x402Adapter).setFacilitatorAuthorization(initialFacilitator, false);
        X402Adapter(fixture.stack.x402Adapter).setFacilitatorAuthorization(finalFacilitator, true);
        vm.stopPrank();

        bytes32[] memory revisionHashes = new bytes32[](1);
        revisionHashes[0] = keccak256(
            abi.encode(
                "planned-facilitator-revision",
                keccak256(bytes(vm.readFile(manifestPath))),
                initialFacilitator,
                finalFacilitator
            )
        );
        address[] memory facilitators = new address[](1);
        facilitators[0] = finalFacilitator;
        bytes32 effectiveHash =
            _writeReleaseInputs(manifestPath, revisionPath, provenancePath, facilitators, revisionHashes);
        _verify(true, false);

        X402Adapter adapter = X402Adapter(fixture.stack.x402Adapter);
        assertEq(adapter.getFacilitatorCount(), 1);
        assertTrue(adapter.authorizedFacilitators(finalFacilitator));
        assertFalse(adapter.authorizedFacilitators(initialFacilitator));
        string memory finalDirectory =
            _archiveEvidence(evidenceRoot, manifestPath, revisionPath, provenancePath, effectiveHash);
        vm.writeFile(
            string.concat(finalDirectory, "/facilitator-revision.json"),
            string.concat(
                '{"kind":"planned","revisionHash":"',
                vm.toString(revisionHashes[0]),
                '","removedFacilitator":"',
                vm.toString(initialFacilitator),
                '","addedFacilitator":"',
                vm.toString(finalFacilitator),
                '","executedBySafe":"',
                vm.toString(safe),
                '"}'
            )
        );
    }

    function _emitThenExecute(string memory mode) private {
        vm.setEnv("GOVERNANCE_BATCH", mode);
        vm.setEnv("EMIT_ONLY", "true");
        executor.run();
        vm.setEnv("EMIT_ONLY", "false");
        executor.run();
    }

    function _verify(bool active, bool paused) private {
        vm.setEnv("DEPLOYMENT_ACTIVE", active ? "true" : "false");
        vm.setEnv("EXTERNAL_DEPENDENCY_PAUSED", paused ? "true" : "false");
        verifier.run();
    }

    function _mockSafeProfile() private {
        vm.etch(safe, SAFE_PROXY_RUNTIME);
        address[] memory owners = new address[](1);
        owners[0] = deployer;
        vm.mockCall(safe, abi.encodeCall(ISafe.masterCopy, ()), abi.encode(SafeDeployment.SAFE_L2_SINGLETON));
        vm.mockCall(safe, abi.encodeCall(ISafe.getOwners, ()), abi.encode(owners));
        vm.mockCall(safe, abi.encodeCall(ISafe.isOwner, (deployer)), abi.encode(true));
        vm.mockCall(safe, abi.encodeCall(ISafe.getThreshold, ()), abi.encode(uint256(1)));
        vm.mockCall(
            safe,
            abi.encodeCall(ISafe.getModulesPaginated, (address(0x1), 1)),
            abi.encode(new address[](0), address(0x1))
        );
        _mockSafeStorage(uint256(keccak256("guard_manager.guard.address")), address(0));
        _mockSafeStorage(
            uint256(keccak256("fallback_manager.handler.address")), SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER
        );
    }

    function _mockSafeStorage(uint256 slot, address value) private {
        bytes memory stored = abi.encode(bytes32(uint256(uint160(value))));
        vm.mockCall(safe, abi.encodeCall(ISafe.getStorageAt, (slot, 1)), abi.encode(stored));
    }
}
