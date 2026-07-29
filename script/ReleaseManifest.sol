// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {DeploymentValidation} from "./DeploymentValidation.sol";
import {SafeDeployment} from "./SafeDeployment.sol";

/// @notice Loads the reviewed release identity used by verification and
///         activation. Expected hashes never come from independent env vars.
abstract contract ReleaseManifest is Script {
    uint256 internal constant CONTRACT_COUNT = 9;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Manifest {
        string source;
        bytes32 hash;
        string phase;
        string sourceCommit;
        string profileVersion;
        DeploymentValidation.Stack stack;
        address eas;
        address schemaRegistry;
        address admin;
        SafeDeployment.Profile governance;
        address[] facilitators;
        address[9] proxies;
        address[9] implementations;
        bytes32[9] proxyCodehashes;
        bytes32[9] implementationCodehashes;
        bytes32 outcomeSchemaUid;
        bytes32 confirmationSchemaUid;
    }

    function _loadManifest() internal view returns (Manifest memory manifest) {
        manifest.source = vm.readFile(vm.envString("RELEASE_MANIFEST_PATH"));
        manifest.hash = keccak256(bytes(manifest.source));
        require(vm.parseJsonUint(manifest.source, ".chainId") == block.chainid, "manifest chain mismatch");

        bool releaseCandidate = _loadBuildIdentity(manifest);
        _loadContracts(manifest);
        _loadConfiguration(manifest, releaseCandidate);
    }

    function _loadBuildIdentity(Manifest memory manifest) private view returns (bool releaseCandidate) {
        manifest.phase = vm.parseJsonString(manifest.source, ".deploymentPhase");
        releaseCandidate = _isReleaseCandidate(manifest.phase);
        manifest.sourceCommit = vm.parseJsonString(manifest.source, ".build.sourceCommit");
        require(bytes(manifest.sourceCommit).length == 40, "invalid source commit");
        require(
            keccak256(bytes(vm.parseJsonString(manifest.source, ".build.solcVersion"))) == keccak256("0.8.24"),
            "wrong manifest solc version"
        );
        require(vm.parseJsonBool(manifest.source, ".build.optimizer"), "optimizer must be enabled");
        require(vm.parseJsonUint(manifest.source, ".build.optimizerRuns") == 200, "wrong optimizer runs");
        require(vm.parseJsonBool(manifest.source, ".build.viaIr"), "via-ir must be enabled");
        manifest.profileVersion = vm.parseJsonString(manifest.source, ".x402.profile");
        require(keccak256(bytes(manifest.profileVersion)) == keccak256("daski-exact/1"), "wrong x402 profile");
    }

    function _loadContracts(Manifest memory manifest) private view {
        string[] memory order = vm.parseJsonStringArray(manifest.source, ".contracts.order");
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

        address[] memory proxies = vm.parseJsonAddressArray(manifest.source, ".contracts.proxies");
        address[] memory implementations = vm.parseJsonAddressArray(manifest.source, ".contracts.implementations");
        bytes32[] memory proxyHashes = vm.parseJsonBytes32Array(manifest.source, ".contracts.proxyRuntimeCodehashes");
        bytes32[] memory implementationHashes =
            vm.parseJsonBytes32Array(manifest.source, ".contracts.implementationRuntimeCodehashes");
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

    function _loadConfiguration(Manifest memory manifest, bool releaseCandidate) private view {
        manifest.stack = _stack(manifest.source, manifest.proxies);
        manifest.eas = vm.parseJsonAddress(manifest.source, ".external.eas");
        manifest.schemaRegistry = vm.parseJsonAddress(manifest.source, ".external.schemaRegistry");
        manifest.admin = vm.parseJsonAddress(manifest.source, ".governance.safe");
        manifest.governance = SafeDeployment.Profile({
            owners: vm.parseJsonAddressArray(manifest.source, ".governance.owners"),
            threshold: vm.parseJsonUint(manifest.source, ".governance.threshold"),
            modules: vm.parseJsonAddressArray(manifest.source, ".governance.modules"),
            guard: vm.parseJsonAddress(manifest.source, ".governance.guard"),
            fallbackHandler: vm.parseJsonAddress(manifest.source, ".governance.fallbackHandler"),
            releaseCandidate: releaseCandidate
        });
        require(
            keccak256(bytes(vm.parseJsonString(manifest.source, ".governance.profile"))) == keccak256("safe-l2-v1.4.1"),
            "unsupported governance profile"
        );
        manifest.facilitators = vm.parseJsonAddressArray(manifest.source, ".x402.authorizedFacilitators");
        require(manifest.facilitators.length > 0, "facilitator set is empty");
        manifest.outcomeSchemaUid = vm.parseJsonBytes32(manifest.source, ".schemas.outcome.uid");
        manifest.confirmationSchemaUid = vm.parseJsonBytes32(manifest.source, ".schemas.confirmation.uid");
    }

    function _latestFacilitators(Manifest memory manifest) internal view returns (address[] memory expected) {
        expected = manifest.facilitators;
        string[] memory noRevisions = new string[](0);
        string[] memory revisionPaths = vm.envOr("RELEASE_MANIFEST_REVISIONS", ",", noRevisions);
        bytes32 previousHash = manifest.hash;
        for (uint256 i = 0; i < revisionPaths.length; i++) {
            string memory revision = vm.readFile(revisionPaths[i]);
            require(vm.parseJsonBool(revision, ".approved"), "manifest revision is not approved");
            require(vm.parseJsonUint(revision, ".revision") == i + 1, "non-monotonic manifest revision");
            require(
                vm.parseJsonBytes32(revision, ".baseManifestHash") == manifest.hash, "revision base manifest mismatch"
            );
            require(
                vm.parseJsonBytes32(revision, ".previousManifestHash") == previousHash, "broken manifest revision link"
            );
            require(vm.parseJsonBytes32(revision, ".safeTransactionHash") != bytes32(0), "missing Safe tx hash");

            address[] memory next = vm.parseJsonAddressArray(revision, ".authorizedFacilitators");
            require(next.length > 0, "revision facilitator set is empty");
            if (keccak256(bytes(vm.parseJsonString(revision, ".kind"))) == keccak256("emergency-remove-only")) {
                _requireSubset(next, expected);
            } else {
                require(
                    keccak256(bytes(vm.parseJsonString(revision, ".kind"))) == keccak256("planned"),
                    "unsupported manifest revision kind"
                );
            }
            expected = next;
            previousHash = keccak256(bytes(revision));
        }
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
        DeploymentValidation.Stack memory deployment = manifest.stack;
        DeploymentValidation.validateExternalDependencies(
            deployment.identity,
            deployment.usdc,
            manifest.eas,
            manifest.schemaRegistry,
            deployment.sanctionsOracle,
            false,
            block.chainid == DeploymentValidation.BASE_SEPOLIA
        );
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
    }

    function _stack(string memory json, address[9] memory proxies)
        private
        view
        returns (DeploymentValidation.Stack memory stack)
    {
        stack = DeploymentValidation.Stack({
            identity: vm.parseJsonAddress(json, ".external.identityRegistry"),
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

    function _requireSubset(address[] memory subset, address[] memory superset) private pure {
        for (uint256 i = 0; i < subset.length; i++) {
            bool found;
            for (uint256 j = 0; j < superset.length; j++) {
                if (subset[i] == superset[j]) found = true;
            }
            require(found, "emergency revision added facilitator");
        }
    }
}
