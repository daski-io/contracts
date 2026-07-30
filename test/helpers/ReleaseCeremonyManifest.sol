// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeploymentValidation} from "../../script/DeploymentValidation.sol";
import {SafeDeployment} from "../../script/SafeDeployment.sol";
import {ReleaseCeremonyStackBuilder, ReleaseCeremonyUsdc} from "./ReleaseCeremonyStack.sol";

abstract contract ReleaseCeremonyManifestBuilder is ReleaseCeremonyStackBuilder {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _writeManifest(
        CeremonyFixture memory fixture,
        string memory buildProfilePath,
        string memory manifestPath,
        address deployer,
        address safe,
        address guardian,
        address facilitator
    ) internal returns (bytes32 manifestHash) {
        string memory build = _buildObject(buildProfilePath);
        string memory contracts_ = _contractsObject(fixture);
        string memory external_ = _externalObject(fixture, deployer);
        string memory economics = _economicsObject(fixture.stack);
        string memory schemas = _schemasObject(fixture);
        string memory governance = _governanceObject(deployer, safe, guardian);
        string memory x402 = _x402Object(facilitator);

        string memory manifest = string.concat(
            '{"chainId":31337,"deploymentPhase":"developer","build":',
            build,
            ',"contracts":',
            contracts_,
            ',"external":',
            external_
        );
        manifest = string.concat(
            manifest,
            ',"economics":',
            economics,
            ',"schemas":',
            schemas,
            ',"governance":',
            governance,
            ',"x402":',
            x402,
            "}"
        );
        vm.writeFile(manifestPath, manifest);
        return keccak256(bytes(vm.readFile(manifestPath)));
    }

    function _writeReleaseInputs(
        string memory manifestPath,
        string memory revisionPath,
        string memory provenancePath,
        address[] memory facilitators,
        bytes32[] memory revisionHashes
    ) internal returns (bytes32 effectiveHash) {
        string memory manifest = vm.readFile(manifestPath);
        bytes32 manifestHash = keccak256(bytes(manifest));
        effectiveHash = _effectiveHash(manifestHash, revisionHashes);

        string memory revisionObject = "ceremonyRevisionEvidence";
        vm.serializeBytes32(revisionObject, "baseManifestHash", manifestHash);
        vm.serializeBytes32(revisionObject, "effectiveReleaseHash", effectiveHash);
        vm.serializeAddress(revisionObject, "effectiveFacilitators", facilitators);
        string memory revision = vm.serializeBytes32(revisionObject, "revisionHashes", revisionHashes);
        vm.writeFile(revisionPath, revision);

        string memory markerObject = "ceremonyProvenance";
        vm.serializeString(markerObject, "schema", "daski-release-provenance/v2");
        vm.serializeBytes32(markerObject, "runId", keccak256("release-ceremony-e2e-run"));
        vm.serializeBytes32(markerObject, "manifestHash", manifestHash);
        vm.serializeBytes32(markerObject, "revisionEvidenceHash", keccak256(bytes(vm.readFile(revisionPath))));
        vm.serializeBytes32(markerObject, "effectiveReleaseHash", effectiveHash);
        vm.serializeBytes32(
            markerObject, "sourceClosureHash", vm.parseJsonBytes32(manifest, ".build.sourceClosureHash")
        );
        vm.serializeBytes32(
            markerObject, "compilerInputHash", vm.parseJsonBytes32(manifest, ".build.compilerInputHash")
        );
        string memory marker = vm.serializeBytes32(
            markerObject, "foundryConfigHash", vm.parseJsonBytes32(manifest, ".build.foundryConfigHash")
        );
        vm.writeFile(provenancePath, marker);

        vm.setEnv("RELEASE_MANIFEST_PATH", manifestPath);
        vm.setEnv("RELEASE_REVISION_EVIDENCE_PATH", revisionPath);
        vm.setEnv("RELEASE_PROVENANCE_PATH", provenancePath);
        vm.setEnv("RELEASE_RUN_ID", vm.toString(keccak256("release-ceremony-e2e-run")));
        vm.setEnv("EFFECTIVE_RELEASE_HASH", vm.toString(effectiveHash));
        vm.setEnv("RELEASE_E2E_LOCAL_FIXTURE", "true");
    }

    function _archiveEvidence(
        string memory evidenceRoot,
        string memory manifestPath,
        string memory revisionPath,
        string memory provenancePath,
        bytes32 effectiveHash
    ) internal returns (string memory finalDirectory) {
        finalDirectory = string.concat(evidenceRoot, "/", vm.toString(effectiveHash));
        vm.createDir(finalDirectory, true);
        vm.copyFile(manifestPath, string.concat(finalDirectory, "/release-manifest.json"));
        vm.copyFile(revisionPath, string.concat(finalDirectory, "/revision-evidence.json"));
        vm.copyFile(provenancePath, string.concat(finalDirectory, "/provenance.json"));
        vm.writeFile(
            string.concat(finalDirectory, "/ceremony-summary.json"),
            string.concat(
                '{"schema":"daski-release-ceremony-e2e/v1","effectiveReleaseHash":"',
                vm.toString(effectiveHash),
                '","modes":["accept","guardian","activate","pause","unpause"],',
                '"emitOnlyAndExecutionCovered":true,"revisionProposalGenerated":true,',
                '"finalizedRevisionVerified":true,"finalFacilitatorSetVerified":true}'
            )
        );
    }

    function _buildObject(string memory path) private returns (string memory) {
        string memory source = vm.readFile(path);
        string memory object = "ceremonyBuild";
        vm.serializeString(object, "sourceCommit", vm.parseJsonString(source, ".build.sourceCommit"));
        vm.serializeBytes32(object, "sourceClosureHash", vm.parseJsonBytes32(source, ".build.sourceClosureHash"));
        vm.serializeBytes32(object, "compilerInputHash", vm.parseJsonBytes32(source, ".build.compilerInputHash"));
        vm.serializeBytes32(object, "foundryConfigHash", vm.parseJsonBytes32(source, ".build.foundryConfigHash"));
        vm.serializeString(object, "solcVersion", vm.parseJsonString(source, ".build.solcVersion"));
        vm.serializeBool(object, "optimizer", vm.parseJsonBool(source, ".build.optimizer"));
        vm.serializeUint(object, "optimizerRuns", vm.parseJsonUint(source, ".build.optimizerRuns"));
        vm.serializeBool(object, "viaIr", vm.parseJsonBool(source, ".build.viaIr"));
        vm.serializeString(object, "evmVersion", vm.parseJsonString(source, ".build.evmVersion"));
        vm.serializeString(object, "foundryVersion", vm.parseJsonString(source, ".build.foundryVersion"));
        return vm.serializeString(object, "foundryCommit", vm.parseJsonString(source, ".build.foundryCommit"));
    }

    function _contractsObject(CeremonyFixture memory fixture) private returns (string memory) {
        string memory object = "ceremonyContracts";
        string[] memory order = new string[](9);
        order[0] = "AgentIndex";
        order[1] = "DaskiValidationRegistry";
        order[2] = "ProviderRegistry";
        order[3] = "ServiceRegistry";
        order[4] = "PaymentRouter";
        order[5] = "ReputationStorage";
        order[6] = "X402Adapter";
        order[7] = "PermitAdapter";
        order[8] = "ApprovalAdapter";
        address[] memory proxies = _addresses(DeploymentValidation.adminContracts(fixture.stack));
        address[] memory implementations = _addresses(fixture.implementations);
        bytes32[] memory proxyHashes = new bytes32[](9);
        bytes32[] memory implementationHashes = new bytes32[](9);
        for (uint256 i = 0; i < 9; i++) {
            proxyHashes[i] = proxies[i].codehash;
            implementationHashes[i] = implementations[i].codehash;
        }
        vm.serializeString(object, "order", order);
        vm.serializeAddress(object, "proxies", proxies);
        vm.serializeAddress(object, "implementations", implementations);
        vm.serializeBytes32(object, "proxyRuntimeCodehashes", proxyHashes);
        return vm.serializeBytes32(object, "implementationRuntimeCodehashes", implementationHashes);
    }

    function _externalObject(CeremonyFixture memory fixture, address deployer) private returns (string memory) {
        string memory identityObject = "ceremonyIdentity";
        vm.serializeAddress(identityObject, "proxy", fixture.stack.identity);
        vm.serializeBytes32(identityObject, "proxyRuntimeCodehash", fixture.stack.identity.codehash);
        vm.serializeAddress(identityObject, "implementation", fixture.identityImplementation);
        vm.serializeBytes32(identityObject, "implementationRuntimeCodehash", fixture.identityImplementation.codehash);
        vm.serializeAddress(identityObject, "erc1967Admin", address(0));
        vm.serializeAddress(identityObject, "upgradeAuthority", deployer);
        string memory identity = vm.serializeString(identityObject, "version", "2.0.0");

        ReleaseCeremonyUsdc usdc = ReleaseCeremonyUsdc(fixture.stack.usdc);
        string memory usdcObject = "ceremonyUsdc";
        vm.serializeAddress(usdcObject, "address", address(usdc));
        vm.serializeUint(usdcObject, "decimals", 6);
        vm.serializeString(usdcObject, "name", "USDC");
        vm.serializeString(usdcObject, "version", "2");
        string memory usdcJson = vm.serializeBytes32(usdcObject, "domainSeparator", usdc.DOMAIN_SEPARATOR());
        return string.concat(
            '{"identityRegistry":',
            identity,
            ',"usdc":',
            usdcJson,
            ',"eas":"',
            vm.toString(fixture.eas),
            '","schemaRegistry":"',
            vm.toString(fixture.eas),
            '","sanctionsOracle":"',
            vm.toString(fixture.stack.sanctionsOracle),
            '"}'
        );
    }

    function _economicsObject(DeploymentValidation.Stack memory stack) private returns (string memory) {
        string memory object = "ceremonyEconomics";
        vm.serializeAddress(object, "providerTreasury", stack.providerTreasury);
        vm.serializeAddress(object, "paymentTreasury", stack.paymentTreasury);
        vm.serializeUint(object, "listingFee", stack.listingFee);
        vm.serializeUint(object, "commissionBps", stack.commissionBps);
        return vm.serializeUint(object, "reputationMinimum", stack.reputationMinimum);
    }

    function _schemasObject(CeremonyFixture memory fixture) private returns (string memory) {
        string memory outcomeObject = "ceremonyOutcomeSchema";
        vm.serializeBytes32(outcomeObject, "uid", fixture.outcomeSchemaUid);
        string memory outcome = vm.serializeString(outcomeObject, "definition", DeploymentValidation.outcomeSchema());
        string memory confirmationObject = "ceremonyConfirmationSchema";
        vm.serializeBytes32(confirmationObject, "uid", fixture.confirmationSchemaUid);
        string memory confirmation =
            vm.serializeString(confirmationObject, "definition", DeploymentValidation.confirmationSchema());
        return string.concat('{"outcome":', outcome, ',"confirmation":', confirmation, "}");
    }

    function _governanceObject(address deployer, address safe, address guardian) private returns (string memory) {
        string memory object = "ceremonyGovernance";
        address[] memory owners = new address[](1);
        owners[0] = deployer;
        vm.serializeString(object, "profile", "safe-l2-v1.4.1");
        vm.serializeAddress(object, "safe", safe);
        vm.serializeAddress(object, "pauseGuardian", guardian);
        vm.serializeAddress(object, "owners", owners);
        vm.serializeUint(object, "threshold", 1);
        vm.serializeAddress(object, "modules", new address[](0));
        vm.serializeAddress(object, "guard", address(0));
        return vm.serializeAddress(object, "fallbackHandler", SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER);
    }

    function _x402Object(address facilitator) private returns (string memory) {
        string memory object = "ceremonyX402";
        address[] memory facilitators = new address[](1);
        facilitators[0] = facilitator;
        vm.serializeString(object, "profile", "daski-exact/1");
        return vm.serializeAddress(object, "authorizedFacilitators", facilitators);
    }

    function _effectiveHash(bytes32 manifestHash, bytes32[] memory revisionHashes) private view returns (bytes32) {
        bytes memory encoded =
            abi.encodePacked(bytes("DASKI_RELEASE_EVIDENCE_V1"), uint256(block.chainid), manifestHash);
        for (uint256 i = 0; i < revisionHashes.length; i++) {
            encoded = abi.encodePacked(encoded, revisionHashes[i]);
        }
        return keccak256(encoded);
    }

    function _addresses(address[9] memory fixedAddresses) private pure returns (address[] memory addresses_) {
        addresses_ = new address[](9);
        for (uint256 i = 0; i < 9; i++) {
            addresses_[i] = fixedAddresses[i];
        }
    }
}
