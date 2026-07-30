// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ReleaseBuildProfile} from "../script/ReleaseBuildProfile.sol";
import {ReleaseManifest} from "../script/ReleaseManifest.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";

contract ReleaseTestImplementation is Admin2StepUpgradeable {
    function initialize() external initializer {}
}

contract ReleaseManifestHarness is ReleaseBuildProfile {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function validateSourceCommit(string calldata sourceCommit) external pure {
        _validateSourceCommit(sourceCommit);
    }

    function validateSchemaDefinitions(string calldata outcome, string calldata confirmation) external pure {
        _validateSchemaDefinitions(outcome, confirmation);
    }

    function validateRuntimeIdentities(
        address proxy,
        address implementation,
        bytes32 proxyHash,
        bytes32 implementationHash
    ) external view {
        require(proxy.codehash == proxyHash, "proxy runtime fingerprint mismatch");
        address actualImplementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(actualImplementation == implementation, "proxy implementation mismatch");
        require(implementation.codehash == implementationHash, "implementation runtime fingerprint mismatch");
        require(IERC1822Proxiable(implementation).proxiableUUID() == IMPLEMENTATION_SLOT, "implementation not UUPS");
    }
}

contract ReleaseProvenanceHarness is ReleaseManifest {
    function deriveEffectiveReleaseHash(uint256 chainId, bytes32 manifestHash, bytes32[] calldata revisionHashes)
        external
        pure
        returns (bytes32)
    {
        return _deriveEffectiveReleaseHash(chainId, manifestHash, revisionHashes);
    }

    function validateProvenance(
        string calldata provenance,
        string calldata revisionEvidence,
        bytes32 manifestHash,
        string calldata source,
        bytes32 effectiveReleaseHash,
        bytes32 expectedRunId
    ) external view {
        _validateProvenance(provenance, revisionEvidence, manifestHash, source, effectiveReleaseHash, expectedRunId);
    }
}

contract ReleaseManifestTest is Test {
    ReleaseManifestHarness private manifest;
    ReleaseProvenanceHarness private provenance;
    bytes32 private constant MANIFEST_HASH = bytes32(uint256(1));
    bytes32 private constant RUN_ID = bytes32(uint256(2));
    bytes32 private constant EFFECTIVE_HASH = bytes32(uint256(3));
    bytes32 private constant SOURCE_CLOSURE_HASH = bytes32(uint256(4));
    bytes32 private constant COMPILER_INPUT_HASH = bytes32(uint256(5));
    bytes32 private constant FOUNDRY_CONFIG_HASH = bytes32(uint256(6));
    string private constant REVISION_EVIDENCE = "{\"effectiveReleaseHash\":\"test\"}\n";

    function setUp() public {
        manifest = new ReleaseManifestHarness();
        provenance = new ReleaseProvenanceHarness();
    }

    function test_acceptsCanonicalBuildIdentityFields() public view {
        manifest.validateSourceCommit("0123456789abcdef0123456789abcdef01234567");
    }

    function test_rejectsUppercaseSourceCommit() public {
        vm.expectRevert("invalid source commit");
        manifest.validateSourceCommit("0123456789abcdef0123456789abcdef0123456A");
    }

    function test_rejectsMalformedSourceCommit() public {
        vm.expectRevert("invalid source commit");
        manifest.validateSourceCommit("0123456789abcdef0123456789abcdef0123456g");
    }

    function test_rejectsShortSourceCommit() public {
        vm.expectRevert("invalid source commit");
        manifest.validateSourceCommit("0123456789abcdef");
    }

    function test_rejectsZeroSourceCommit() public {
        vm.expectRevert("zero source commit");
        manifest.validateSourceCommit("0000000000000000000000000000000000000000");
    }

    function test_acceptsCanonicalSchemaDefinitions() public view {
        manifest.validateSchemaDefinitions("uint256 paymentId,uint8 outcome", "uint256 paymentId,uint8 confirmation");
    }

    function test_rejectsMismatchedOutcomeDefinition() public {
        vm.expectRevert("wrong manifest outcome schema");
        manifest.validateSchemaDefinitions("uint256 paymentId,uint256 outcome", "uint256 paymentId,uint8 confirmation");
    }

    function test_rejectsMismatchedConfirmationDefinition() public {
        vm.expectRevert("wrong manifest confirmation schema");
        manifest.validateSchemaDefinitions("uint256 paymentId,uint8 outcome", "uint256 paymentId,uint256 confirmation");
    }

    function test_acceptsMatchingProxyImplementationAndRuntimeHashes() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        manifest.validateRuntimeIdentities(
            address(proxy), address(implementation), address(proxy).codehash, address(implementation).codehash
        );
    }

    function test_rejectsProxyRuntimeHashMismatch() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        vm.expectRevert("proxy runtime fingerprint mismatch");
        manifest.validateRuntimeIdentities(
            address(proxy), address(implementation), bytes32(uint256(1)), address(implementation).codehash
        );
    }

    function test_rejectsProxyImplementationMismatch() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ReleaseTestImplementation other = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        vm.expectRevert("proxy implementation mismatch");
        manifest.validateRuntimeIdentities(
            address(proxy), address(other), address(proxy).codehash, address(other).codehash
        );
    }

    function test_rejectsImplementationRuntimeHashMismatch() public {
        ReleaseTestImplementation implementation = new ReleaseTestImplementation();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ReleaseTestImplementation.initialize, ()));

        vm.expectRevert("implementation runtime fingerprint mismatch");
        manifest.validateRuntimeIdentities(
            address(proxy), address(implementation), address(proxy).codehash, bytes32(uint256(1))
        );
    }

    function test_acceptsV2ProvenanceBoundToRunAndEffectiveRelease() public view {
        provenance.validateProvenance(
            _marker(RUN_ID, keccak256(bytes(REVISION_EVIDENCE)), EFFECTIVE_HASH, SOURCE_CLOSURE_HASH),
            REVISION_EVIDENCE,
            MANIFEST_HASH,
            _source(),
            EFFECTIVE_HASH,
            RUN_ID
        );
    }

    function test_rejectsMarkerFromAnotherWrapperRun() public {
        vm.expectRevert("wrong provenance run");
        provenance.validateProvenance(
            _marker(RUN_ID, keccak256(bytes(REVISION_EVIDENCE)), EFFECTIVE_HASH, SOURCE_CLOSURE_HASH),
            REVISION_EVIDENCE,
            MANIFEST_HASH,
            _source(),
            EFFECTIVE_HASH,
            bytes32(uint256(99))
        );
    }

    function test_rejectsMarkerForDifferentRevisionEvidence() public {
        vm.expectRevert("wrong provenance revision evidence");
        provenance.validateProvenance(
            _marker(RUN_ID, bytes32(uint256(99)), EFFECTIVE_HASH, SOURCE_CLOSURE_HASH),
            REVISION_EVIDENCE,
            MANIFEST_HASH,
            _source(),
            EFFECTIVE_HASH,
            RUN_ID
        );
    }

    function test_rejectsMarkerForDifferentEffectiveRelease() public {
        vm.expectRevert("wrong provenance effective release");
        provenance.validateProvenance(
            _marker(RUN_ID, keccak256(bytes(REVISION_EVIDENCE)), bytes32(uint256(99)), SOURCE_CLOSURE_HASH),
            REVISION_EVIDENCE,
            MANIFEST_HASH,
            _source(),
            EFFECTIVE_HASH,
            RUN_ID
        );
    }

    function test_rejectsMarkerForDifferentBuild() public {
        vm.expectRevert("wrong provenance source closure");
        provenance.validateProvenance(
            _marker(RUN_ID, keccak256(bytes(REVISION_EVIDENCE)), EFFECTIVE_HASH, bytes32(uint256(99))),
            REVISION_EVIDENCE,
            MANIFEST_HASH,
            _source(),
            EFFECTIVE_HASH,
            RUN_ID
        );
    }

    function test_rejectsOldMarkerSchema() public {
        vm.expectRevert("wrong provenance schema");
        provenance.validateProvenance(
            _markerWithSchema(
                "daski-release-provenance/v1",
                RUN_ID,
                keccak256(bytes(REVISION_EVIDENCE)),
                EFFECTIVE_HASH,
                SOURCE_CLOSURE_HASH
            ),
            REVISION_EVIDENCE,
            MANIFEST_HASH,
            _source(),
            EFFECTIVE_HASH,
            RUN_ID
        );
    }

    function test_rejectsMissingMarker() public {
        vm.expectRevert();
        provenance.validateProvenance("", REVISION_EVIDENCE, MANIFEST_HASH, _source(), EFFECTIVE_HASH, RUN_ID);
    }

    function test_derivesEffectiveReleaseFromOrderedRevisionHashes() public view {
        bytes32[] memory revisions = _revisions(bytes32(uint256(7)), bytes32(uint256(8)));
        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes("DASKI_RELEASE_EVIDENCE_V1"),
                uint256(8453),
                MANIFEST_HASH,
                bytes32(uint256(7)),
                bytes32(uint256(8))
            )
        );

        assertEq(provenance.deriveEffectiveReleaseHash(8453, MANIFEST_HASH, revisions), expected);
        assertNotEq(
            provenance.deriveEffectiveReleaseHash(
                8453, MANIFEST_HASH, _revisions(bytes32(uint256(8)), bytes32(uint256(7)))
            ),
            expected
        );
    }

    function test_rejectsZeroRevisionHashInEffectiveRelease() public {
        vm.expectRevert("zero revision hash");
        provenance.deriveEffectiveReleaseHash(8453, MANIFEST_HASH, _revisions(bytes32(uint256(7)), bytes32(0)));
    }

    function _revisions(bytes32 first, bytes32 second) private pure returns (bytes32[] memory revisions) {
        revisions = new bytes32[](2);
        revisions[0] = first;
        revisions[1] = second;
    }

    function _source() private pure returns (string memory) {
        return string.concat(
            "{\"build\":{\"sourceClosureHash\":\"",
            vm.toString(SOURCE_CLOSURE_HASH),
            "\",\"compilerInputHash\":\"",
            vm.toString(COMPILER_INPUT_HASH),
            "\",\"foundryConfigHash\":\"",
            vm.toString(FOUNDRY_CONFIG_HASH),
            "\"}}"
        );
    }

    function _marker(bytes32 runId, bytes32 revisionHash, bytes32 effectiveHash, bytes32 sourceClosureHash)
        private
        pure
        returns (string memory)
    {
        return _markerWithSchema("daski-release-provenance/v2", runId, revisionHash, effectiveHash, sourceClosureHash);
    }

    function _markerWithSchema(
        string memory schema,
        bytes32 runId,
        bytes32 revisionHash,
        bytes32 effectiveHash,
        bytes32 sourceClosureHash
    ) private pure returns (string memory) {
        return string.concat(
            "{\"schema\":\"",
            schema,
            "\",\"runId\":\"",
            vm.toString(runId),
            "\",\"manifestHash\":\"",
            vm.toString(MANIFEST_HASH),
            "\",\"revisionEvidenceHash\":\"",
            vm.toString(revisionHash),
            "\",\"effectiveReleaseHash\":\"",
            vm.toString(effectiveHash),
            "\",\"sourceClosureHash\":\"",
            vm.toString(sourceClosureHash),
            "\",\"compilerInputHash\":\"",
            vm.toString(COMPILER_INPUT_HASH),
            "\",\"foundryConfigHash\":\"",
            vm.toString(FOUNDRY_CONFIG_HASH),
            "\"}"
        );
    }
}
