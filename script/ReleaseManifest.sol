// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {ExternalIdentityValidation} from "./ExternalIdentityValidation.sol";
import {ReleaseBuildProfile} from "./ReleaseBuildProfile.sol";
import {SafeDeployment} from "./SafeDeployment.sol";

/// @notice Loads the reviewed release identity used by verification and
///         activation. Expected hashes never come from independent env vars.
abstract contract ReleaseManifest is ReleaseBuildProfile, ExternalIdentityValidation {
    uint256 internal constant CONTRACT_COUNT = 9;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Manifest {
        bytes32 hash;
        DeploymentValidation.Stack stack;
        address eas;
        address schemaRegistry;
        address admin;
        address pauseGuardian;
        SafeDeployment.Profile governance;
        address[9] proxies;
        address[9] implementations;
        bytes32[9] proxyCodehashes;
        bytes32[9] implementationCodehashes;
        bytes32 outcomeSchemaUid;
        bytes32 confirmationSchemaUid;
    }

    struct RevisionState {
        address[] facilitators;
        bytes32 effectiveHash;
    }

    function _loadManifest() internal view returns (Manifest memory manifest) {
        string memory source = vm.readFile(vm.envString("RELEASE_MANIFEST_PATH"));
        manifest.hash = keccak256(bytes(source));
        require(vm.parseJsonUint(source, ".chainId") == block.chainid, "manifest chain mismatch");

        bool releaseCandidate = _loadBuildIdentity(source);
        _loadContracts(manifest, source);
        _loadConfiguration(manifest, source, releaseCandidate);
        _requireProvenance(manifest.hash, source);
    }

    function _requireProvenance(bytes32 manifestHash, string memory source) private view {
        string memory provenance = vm.readFile(vm.envString("RELEASE_PROVENANCE_PATH"));
        require(vm.parseJsonBytes32(provenance, ".manifestHash") == manifestHash, "wrong provenance manifest");
        require(
            vm.parseJsonBytes32(provenance, ".sourceClosureHash")
                == vm.parseJsonBytes32(source, ".build.sourceClosureHash"),
            "wrong provenance source closure"
        );
        require(
            vm.parseJsonBytes32(provenance, ".compilerInputHash")
                == vm.parseJsonBytes32(source, ".build.compilerInputHash"),
            "wrong provenance compiler input"
        );
        require(
            vm.parseJsonBytes32(provenance, ".foundryConfigHash")
                == vm.parseJsonBytes32(source, ".build.foundryConfigHash"),
            "wrong provenance Foundry config"
        );
    }

    function _loadBuildIdentity(string memory source) private view returns (bool releaseCandidate) {
        releaseCandidate = _isReleaseCandidate(vm.parseJsonString(source, ".deploymentPhase"));
        _validateBuildProfile(source, vm.parseJsonString(source, ".build.sourceCommit"));
        require(
            keccak256(bytes(vm.parseJsonString(source, ".x402.profile"))) == keccak256("daski-exact/1"),
            "wrong x402 profile"
        );
    }

    function _loadContracts(Manifest memory manifest, string memory source) private view {
        string[] memory order = vm.parseJsonStringArray(source, ".contracts.order");
        bytes32[9] memory expectedOrder = [
            keccak256("AgentIndex"),
            keccak256("DaskiValidationRegistry"),
            keccak256("ProviderRegistry"),
            keccak256("ServiceRegistry"),
            keccak256("PaymentRouter"),
            keccak256("ReputationStorage"),
            keccak256("X402Adapter"),
            keccak256("PermitAdapter"),
            keccak256("ApprovalAdapter")
        ];
        require(order.length == CONTRACT_COUNT, "manifest contract order must contain nine entries");
        for (uint256 i = 0; i < CONTRACT_COUNT; i++) {
            require(keccak256(bytes(order[i])) == expectedOrder[i], "wrong manifest contract order");
        }

        address[] memory proxies = vm.parseJsonAddressArray(source, ".contracts.proxies");
        address[] memory implementations = vm.parseJsonAddressArray(source, ".contracts.implementations");
        bytes32[] memory proxyHashes = vm.parseJsonBytes32Array(source, ".contracts.proxyRuntimeCodehashes");
        bytes32[] memory implementationHashes =
            vm.parseJsonBytes32Array(source, ".contracts.implementationRuntimeCodehashes");
        require(
            proxies.length == CONTRACT_COUNT && implementations.length == CONTRACT_COUNT
                && proxyHashes.length == CONTRACT_COUNT && implementationHashes.length == CONTRACT_COUNT,
            "manifest contract arrays must contain nine entries"
        );
        for (uint256 i = 0; i < CONTRACT_COUNT; i++) {
            require(proxies[i] != address(0) && implementations[i] != address(0), "zero manifest contract");
            require(proxyHashes[i] != bytes32(0) && implementationHashes[i] != bytes32(0), "zero runtime fingerprint");
            manifest.proxies[i] = proxies[i];
            manifest.implementations[i] = implementations[i];
            manifest.proxyCodehashes[i] = proxyHashes[i];
            manifest.implementationCodehashes[i] = implementationHashes[i];
        }
    }

    function _loadConfiguration(Manifest memory manifest, string memory source, bool releaseCandidate) private view {
        manifest.stack = _stack(source, manifest.proxies);
        manifest.eas = vm.parseJsonAddress(source, ".external.eas");
        manifest.schemaRegistry = vm.parseJsonAddress(source, ".external.schemaRegistry");
        manifest.admin = vm.parseJsonAddress(source, ".governance.safe");
        manifest.pauseGuardian = vm.parseJsonAddress(source, ".governance.pauseGuardian");
        if (releaseCandidate) require(manifest.pauseGuardian != address(0), "release guardian required");
        manifest.governance = _loadGovernance(source, releaseCandidate);
        require(
            keccak256(bytes(vm.parseJsonString(source, ".governance.profile"))) == keccak256("safe-l2-v1.4.1"),
            "unsupported governance profile"
        );
        require(vm.parseJsonAddressArray(source, ".x402.authorizedFacilitators").length > 0, "facilitator set is empty");
        manifest.outcomeSchemaUid = vm.parseJsonBytes32(source, ".schemas.outcome.uid");
        manifest.confirmationSchemaUid = vm.parseJsonBytes32(source, ".schemas.confirmation.uid");
        _validateSchemaDefinitions(
            vm.parseJsonString(source, ".schemas.outcome.definition"),
            vm.parseJsonString(source, ".schemas.confirmation.definition")
        );
    }

    function _loadGovernance(string memory source, bool releaseCandidate)
        private
        view
        returns (SafeDeployment.Profile memory governance)
    {
        governance.owners = vm.parseJsonAddressArray(source, ".governance.owners");
        governance.threshold = vm.parseJsonUint(source, ".governance.threshold");
        governance.modules = vm.parseJsonAddressArray(source, ".governance.modules");
        governance.guard = vm.parseJsonAddress(source, ".governance.guard");
        governance.fallbackHandler = vm.parseJsonAddress(source, ".governance.fallbackHandler");
        governance.releaseCandidate = releaseCandidate;
    }

    function _latestFacilitators(Manifest memory manifest) internal view returns (address[] memory expected) {
        return _revisionState(manifest).facilitators;
    }

    function _effectiveReleaseHash(Manifest memory manifest) internal view returns (bytes32) {
        return _revisionState(manifest).effectiveHash;
    }

    function _revisionState(Manifest memory manifest) private view returns (RevisionState memory state) {
        string memory evidence = vm.readFile(vm.envString("RELEASE_REVISION_EVIDENCE_PATH"));
        require(vm.parseJsonBytes32(evidence, ".baseManifestHash") == manifest.hash, "wrong revision base manifest");
        state.effectiveHash = vm.parseJsonBytes32(evidence, ".effectiveReleaseHash");
        require(state.effectiveHash == vm.envBytes32("EFFECTIVE_RELEASE_HASH"), "wrong effective release hash");
        state.facilitators = vm.parseJsonAddressArray(evidence, ".effectiveFacilitators");
        require(state.facilitators.length > 0, "effective facilitator set is empty");
    }

    function _validateRuntimeIdentities(Manifest memory manifest) internal view {
        for (uint256 i = 0; i < CONTRACT_COUNT; i++) {
            address proxy = manifest.proxies[i];
            require(proxy.codehash == manifest.proxyCodehashes[i], "proxy runtime fingerprint mismatch");
            address implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
            require(implementation == manifest.implementations[i], "proxy implementation mismatch");
            require(
                implementation.codehash == manifest.implementationCodehashes[i],
                "implementation runtime fingerprint mismatch"
            );
            require(IERC1822Proxiable(implementation).proxiableUUID() == IMPLEMENTATION_SLOT, "implementation not UUPS");
        }
    }

    function _validateManifestCore(Manifest memory manifest) internal view {
        _validateExternalManifestCore(manifest);
        _validateDaskiCore(manifest, false, true);
    }

    function _validateGuardianConfigurationCore(Manifest memory manifest) internal view {
        _validateExternalManifestCore(manifest);
        _validateDaskiCore(manifest, false, false);
    }

    function _validateExternalManifestCore(Manifest memory manifest) private view {
        DeploymentValidation.Stack memory deployment = manifest.stack;
        _validateExternalIdentity(manifest);
        DeploymentValidation.validateExternalDependencies(
            deployment.identity,
            deployment.usdc,
            manifest.eas,
            manifest.schemaRegistry,
            deployment.sanctionsOracle,
            false,
            block.chainid == DeploymentValidation.BASE_SEPOLIA
        );
    }

    function _validatePausedManifestCore(Manifest memory manifest, bool expectedPaused) internal view {
        _validateDaskiCore(manifest, expectedPaused, true);
    }

    function _validateUnpauseManifestCore(Manifest memory manifest) internal view {
        _validateExternalIdentity(manifest);
        DeploymentValidation.validateExternalDependencies(
            manifest.stack.identity,
            manifest.stack.usdc,
            manifest.eas,
            manifest.schemaRegistry,
            manifest.stack.sanctionsOracle,
            false,
            block.chainid == DeploymentValidation.BASE_SEPOLIA
        );
        _validateDaskiCore(manifest, true, true);
    }

    function _validateDaskiCore(Manifest memory manifest, bool expectedPaused, bool validateGuards) private view {
        DeploymentValidation.Stack memory deployment = manifest.stack;
        DeploymentValidation.validateSchemas(
            manifest.eas,
            manifest.schemaRegistry,
            deployment.reputation,
            manifest.outcomeSchemaUid,
            manifest.confirmationSchemaUid,
            DeploymentValidation.outcomeSchema(),
            DeploymentValidation.confirmationSchema()
        );
        DeploymentValidation.validateCoreWiring(deployment);
        DeploymentValidation.validateFacilitators(deployment.x402Adapter, _latestFacilitators(manifest));
        _validateRuntimeIdentities(manifest);
        if (validateGuards) {
            DeploymentValidation.validateExternalDependencyGuards(
                DeploymentValidation.adminContracts(deployment), manifest.pauseGuardian, expectedPaused
            );
        }
    }

    function _validateExternalIdentity(Manifest memory manifest) internal view {
        string memory source = vm.readFile(vm.envString("RELEASE_MANIFEST_PATH"));
        _validateExternalIdentityFromManifest(source, manifest.stack.identity);
    }

    function _stack(string memory json, address[9] memory proxies)
        private
        view
        returns (DeploymentValidation.Stack memory stack)
    {
        stack = DeploymentValidation.Stack({
            identity: vm.parseJsonAddress(json, ".external.identityRegistry.proxy"),
            usdc: vm.parseJsonAddress(json, ".external.usdc"),
            providerTreasury: vm.parseJsonAddress(json, ".economics.providerTreasury"),
            paymentTreasury: vm.parseJsonAddress(json, ".economics.paymentTreasury"),
            sanctionsOracle: vm.parseJsonAddress(json, ".external.sanctionsOracle"),
            agentIndex: proxies[0],
            daskiValidationRegistry: proxies[1],
            providerRegistry: proxies[2],
            serviceRegistry: proxies[3],
            router: proxies[4],
            reputation: proxies[5],
            x402Adapter: proxies[6],
            permitAdapter: proxies[7],
            approvalAdapter: proxies[8],
            listingFee: vm.parseJsonUint(json, ".economics.listingFee"),
            commissionBps: vm.parseJsonUint(json, ".economics.commissionBps"),
            reputationMinimum: vm.parseJsonUint(json, ".economics.reputationMinimum")
        });
    }

    function _isReleaseCandidate(string memory phase) private view returns (bool) {
        bytes32 phaseHash = keccak256(bytes(phase));
        if (block.chainid == DeploymentValidation.BASE_MAINNET) {
            require(phaseHash == keccak256("mainnet"), "mainnet manifest phase required");
            return true;
        }
        require(
            phaseHash == keccak256("developer") || phaseHash == keccak256("release-candidate"),
            "unsupported deployment phase"
        );
        return phaseHash == keccak256("release-candidate");
    }
}
