#!/usr/bin/env python3
"""Verify that a release manifest matches locally reproduced runtime bytecode."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

CONTRACTS = (
    "AgentIndex",
    "DaskiValidationRegistry",
    "ProviderRegistry",
    "ServiceRegistry",
    "PaymentRouter",
    "ReputationStorage",
    "X402Adapter",
    "PermitAdapter",
    "ApprovalAdapter",
)
SOLC_VERSION = "0.8.24+commit.e11b9ed9"
EVM_VERSION = "cancun"
FOUNDRY_VERSION = "1.5.1-stable"
FOUNDRY_VERSION_OUTPUTS = frozenset({"1.5.1-stable", "1.5.1-v1.5.1"})
FOUNDRY_COMMIT = "b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2"
OUTCOME_SCHEMA = "uint256 paymentId,uint8 outcome"
CONFIRMATION_SCHEMA = "uint256 paymentId,uint8 confirmation"
UUPS_SOURCE = "lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol"
HASH_FIELDS = ("sourceClosureHash", "compilerInputHash", "foundryConfigHash")
SOLC_INPUT_DOMAIN = b"DASKI_SOLC_INPUT_V1"
SOLC_INPUT_SET_DOMAIN = b"DASKI_COMPILER_INPUT_SET_V1"
SOURCE_CLOSURE_DOMAIN = b"DASKI_SOURCE_CLOSURE_V1"
REQUIRED_TARGETS = {
    **{contract: (f"src/{contract}.sol", contract) for contract in CONTRACTS if contract not in {"X402Adapter", "PermitAdapter", "ApprovalAdapter"}},
    "X402Adapter": ("src/adapters/X402Adapter.sol", "X402Adapter"),
    "PermitAdapter": ("src/adapters/PermitAdapter.sol", "PermitAdapter"),
    "ApprovalAdapter": ("src/adapters/ApprovalAdapter.sol", "ApprovalAdapter"),
    "ERC1967Proxy": (
        "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol",
        "ERC1967Proxy",
    ),
    "Deploy": ("script/Deploy.s.sol", "Deploy"),
    "VerifyDeployment": ("script/VerifyDeployment.s.sol", "VerifyDeployment"),
    "ExecuteGovernanceBatches": (
        "script/ExecuteGovernanceBatches.s.sol",
        "ExecuteGovernanceBatches",
    ),
}
USDC_DOMAINS = {
    8453: {
        "address": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        "decimals": 6,
        "name": "USD Coin",
        "version": "2",
        "domainSeparator": "0x02fa7265e7c5d81118673727957699e4d68f74cd74b7db77da710fe8a2c7834f",
    },
    84532: {
        "address": "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
        "decimals": 6,
        "name": "USDC",
        "version": "2",
        "domainSeparator": "0x71f17a3b2ff373b803d70a5a07c046c1a2bc8e89c09ef722fcb047abe94c9818",
    },
}


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def command_output(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or f"{command[0]} failed")
    return result.stdout.strip()


def keccak(data: bytes, cast: str) -> str:
    result = subprocess.run(
        [cast, "keccak"],
        input=b"0x" + data.hex().encode("ascii"),
        check=False,
        capture_output=True,
    )
    require(
        result.returncode == 0,
        result.stderr.decode(errors="replace").strip() or "cast keccak failed",
    )
    value = result.stdout.decode().strip().lower()
    require(re.fullmatch(r"0x[0-9a-f]{64}", value) is not None, "cast returned an invalid hash")
    return value


def parse_toolchain(output: str, tool: str) -> tuple[str, str]:
    version = re.search(rf"^{tool} Version: (.+)$", output, re.MULTILINE)
    commit = re.search(r"^Commit SHA: ([0-9a-f]{40})$", output, re.MULTILINE)
    require(version is not None and commit is not None, f"unrecognized {tool} --version output")
    require(version.group(1) in FOUNDRY_VERSION_OUTPUTS, f"unsupported {tool} version")
    return FOUNDRY_VERSION, commit.group(1)


def validate_manifest(manifest: dict[str, Any], forge_output: str) -> None:
    build = manifest.get("build", {})
    source_commit = build.get("sourceCommit", "")
    require(re.fullmatch(r"[0-9a-f]{40}", source_commit) is not None, "invalid source commit")
    require(source_commit != "0" * 40, "zero source commit")
    for field in HASH_FIELDS:
        value = build.get(field, "")
        require(re.fullmatch(r"0x[0-9a-f]{64}", value) is not None, f"invalid {field}")
        require(int(value, 16) != 0, f"zero {field}")
    require(build.get("solcVersion") == SOLC_VERSION, "wrong manifest solc version")
    require(build.get("optimizer") is True, "optimizer must be enabled")
    require(build.get("optimizerRuns") == 200, "wrong optimizer runs")
    require(build.get("viaIr") is True, "via-ir must be enabled")
    require(build.get("evmVersion") == EVM_VERSION, "wrong manifest EVM version")
    version, commit = parse_toolchain(forge_output, "forge")
    require(build.get("foundryVersion") == version == FOUNDRY_VERSION, "wrong Foundry version")
    require(build.get("foundryCommit") == commit == FOUNDRY_COMMIT, "wrong Foundry commit")
    schemas = manifest.get("schemas", {})
    require(schemas.get("outcome", {}).get("definition") == OUTCOME_SCHEMA, "wrong outcome schema")
    require(
        schemas.get("confirmation", {}).get("definition") == CONFIRMATION_SCHEMA,
        "wrong confirmation schema",
    )
    contracts = manifest.get("contracts", {})
    require(contracts.get("order") == list(CONTRACTS), "wrong manifest contract order")
    for field in ("proxies", "implementations", "proxyRuntimeCodehashes", "implementationRuntimeCodehashes"):
        require(len(contracts.get(field, [])) == len(CONTRACTS), f"{field} must contain nine entries")
    for field in ("proxies", "implementations"):
        for address in contracts[field]:
            require(re.fullmatch(r"0x[0-9a-fA-F]{40}", address) is not None, f"invalid {field} address")
            require(int(address, 16) != 0, f"zero {field} address")
    for field in ("proxyRuntimeCodehashes", "implementationRuntimeCodehashes"):
        for codehash in contracts[field]:
            require(re.fullmatch(r"0x[0-9a-fA-F]{64}", codehash) is not None, f"invalid {field} hash")
            require(int(codehash, 16) != 0, f"zero {field} hash")
    chain_id = manifest.get("chainId")
    require(chain_id in USDC_DOMAINS, "unsupported manifest chain")
    usdc = manifest.get("external", {}).get("usdc")
    require(isinstance(usdc, dict), "external.usdc must be an object")
    normalized_usdc = dict(usdc)
    if isinstance(normalized_usdc.get("address"), str):
        normalized_usdc["address"] = normalized_usdc["address"].lower()
    if isinstance(normalized_usdc.get("domainSeparator"), str):
        normalized_usdc["domainSeparator"] = normalized_usdc["domainSeparator"].lower()
    require(normalized_usdc == USDC_DOMAINS[chain_id], "wrong reviewed USDC domain")


def validate_metadata(artifact: dict[str, Any]) -> None:
    metadata = artifact.get("metadata")
    require(isinstance(metadata, dict), "artifact metadata is missing")
    settings = metadata.get("settings", {})
    optimizer = settings.get("optimizer", {})
    require(metadata.get("compiler", {}).get("version") == SOLC_VERSION, "artifact solc version mismatch")
    require(optimizer.get("enabled") is True and optimizer.get("runs") == 200, "artifact optimizer mismatch")
    require(settings.get("viaIR") is True, "artifact viaIR mismatch")
    require(settings.get("evmVersion") == EVM_VERSION, "artifact EVM version mismatch")


def artifact_at(output: Path, contract: str) -> dict[str, Any]:
    path = output / f"{contract}.sol" / f"{contract}.json"
    require(path.is_file(), f"missing artifact: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def _git_bytes(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=repo, check=False, capture_output=True)
    require(result.returncode == 0, result.stderr.decode(errors="replace").strip() or "git object read failed")
    return result.stdout


def _submodule_identities(repo: Path) -> list[tuple[Path, str, str]]:
    result = subprocess.run(
        ["git", "submodule", "status", "--recursive"],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0, result.stderr.strip() or "git submodule status failed")
    identities: list[tuple[Path, str, str]] = []
    for line in result.stdout.splitlines():
        require(line.startswith(" "), "submodule commit does not match its recorded gitlink")
        commit, path, *_ = line[1:].split()
        identities.append(((repo / path).resolve(), path, commit))
    return sorted(identities, key=lambda item: len(item[1]), reverse=True)


def _source_git_bytes(
    repo: Path, source_commit: str, logical_path: str, submodules: list[tuple[Path, str, str]]
) -> tuple[str, bytes]:
    require("\\" not in logical_path, f"non-canonical source path: {logical_path}")
    relative = Path(logical_path)
    require(not relative.is_absolute() and ".." not in relative.parts, f"source escapes repository: {logical_path}")
    resolved = (repo / relative).resolve()
    try:
        resolved.relative_to(repo.resolve())
    except ValueError as error:
        raise VerificationError(f"source escapes repository: {logical_path}") from error

    for submodule_root, submodule_path, commit in submodules:
        try:
            nested = resolved.relative_to(submodule_root).as_posix()
        except ValueError:
            continue
        _git_bytes(submodule_root, "ls-files", "--error-unmatch", "--", nested)
        return f"{submodule_path}@{commit}", _git_bytes(submodule_root, "show", f"{commit}:{nested}")

    normalized = relative.as_posix()
    _git_bytes(repo, "ls-files", "--error-unmatch", "--", normalized)
    return f"root@{source_commit}", _git_bytes(repo, "show", f"{source_commit}:{normalized}")


def _length_prefixed(values: list[bytes]) -> bytes:
    encoded = len(values).to_bytes(8, "big")
    for value in values:
        encoded += len(value).to_bytes(8, "big") + value
    return encoded


def _artifact_for_target(output: Path, source: str, contract: str) -> dict[str, Any]:
    path = output / Path(source).name / f"{contract}.json"
    require(path.is_file(), f"missing required target artifact: {source}:{contract}")
    artifact = json.loads(path.read_text(encoding="utf-8"))
    target = artifact.get("metadata", {}).get("settings", {}).get("compilationTarget")
    require(target == {source: contract}, f"wrong artifact compilation target: {source}:{contract}")
    return artifact


def _selects_target(settings: dict[str, Any], source: str, contract: str) -> bool:
    selection = settings.get("outputSelection")
    if not isinstance(selection, dict):
        return False
    for source_key in (source, "*"):
        contracts = selection.get(source_key)
        if not isinstance(contracts, dict):
            continue
        for contract_key in (contract, "*"):
            outputs = contracts.get(contract_key)
            if isinstance(outputs, list) and outputs:
                return True
    return False


def _canonical_remappings(value: Any) -> list[str]:
    require(isinstance(value, list), "compiler remappings must be a list")
    identities: set[str] = set()
    remappings: list[str] = []
    for remapping in value:
        require(isinstance(remapping, str), "compiler remapping must be a string")
        identity, separator, target = remapping.partition("=")
        require(separator == "=" and identity and target, f"invalid compiler remapping: {remapping}")
        require(identity not in identities, f"duplicate compiler remapping identity: {identity}")
        identities.add(identity)
        remappings.append(remapping)
    return sorted(remappings)


def _validate_metadata_against_unit(
    artifact: dict[str, Any],
    unit: dict[str, Any],
    source_hashes: dict[str, str],
) -> None:
    metadata = artifact.get("metadata")
    require(isinstance(metadata, dict), "artifact metadata is missing")
    require(metadata.get("compiler") == unit["compiler"], "build-info and artifact compiler mismatch")
    metadata_settings = metadata.get("settings", {})
    unit_settings = unit["settings"]
    for field in ("optimizer", "viaIR", "evmVersion", "libraries"):
        require(
            metadata_settings.get(field) == unit_settings.get(field),
            f"build-info and artifact {field} mismatch",
        )
    require(
        _canonical_remappings(metadata_settings.get("remappings"))
        == _canonical_remappings(unit_settings.get("remappings")),
        "build-info and artifact remappings mismatch",
    )
    for path, source in metadata.get("sources", {}).items():
        require(path in source_hashes, f"artifact source missing from selected compiler input: {path}")
        require(
            source.get("keccak256", "").lower() == source_hashes[path],
            f"build-info and artifact source mismatch: {path}",
        )


def calculate_source_closure(
    repo: Path,
    output: Path,
    build_info: Path,
    source_commit: str,
    cast: str,
) -> dict[str, Any]:
    submodules = _submodule_identities(repo)
    sources: dict[str, tuple[str, str]] = {}
    compiler_units: dict[str, dict[str, Any]] = {}
    capture_paths = sorted((build_info / "compiler-inputs").glob("*.json"))
    require(capture_paths, "captured compiler input is empty")

    for capture_path in capture_paths:
        capture = json.loads(capture_path.read_text(encoding="utf-8"))
        require(capture.get("schema") == "daski-solc-input/v1", "unsupported compiler input capture")
        require(capture_path.stem == capture.get("inputSha256"), "compiler input capture filename mismatch")
        compiler = capture.get("compiler")
        compiler_input = capture.get("input")
        require(compiler == {"version": SOLC_VERSION}, "wrong captured compiler identity")
        require(isinstance(compiler_input, dict), "malformed captured compiler input")
        require(compiler_input.get("language") == "Solidity", "unsupported compiler input language")
        settings = compiler_input.get("settings")
        input_sources = compiler_input.get("sources")
        require(isinstance(settings, dict), "compiler input settings are missing")
        require(isinstance(input_sources, dict) and input_sources, "compiler input sources are empty")
        normalized_sources: dict[str, str] = {}
        for logical_path, source_data in input_sources.items():
            require(
                isinstance(source_data, dict) and isinstance(source_data.get("content"), str),
                f"compiler input source content is missing: {logical_path}",
            )
            repository_identity, git_content = _source_git_bytes(
                repo, source_commit, logical_path, submodules
            )
            require(
                source_data["content"].encode() == git_content,
                f"compiler input differs from Git object: {logical_path}",
            )
            actual_hash = keccak(git_content, cast)
            prior = sources.get(logical_path)
            current = (repository_identity, actual_hash)
            require(prior is None or prior == current, f"conflicting source identity: {logical_path}")
            sources[logical_path] = current
            normalized_sources[logical_path] = actual_hash

        unit = {
            "compiler": compiler,
            "language": compiler_input["language"],
            "settings": settings,
            "sources": dict(sorted(normalized_sources.items())),
        }
        unit_hash = keccak(SOLC_INPUT_DOMAIN + canonical_json(unit), cast)
        require(unit_hash not in compiler_units, "duplicate captured compiler input")
        compiler_units[unit_hash] = unit

    require(sources, "compiler source closure is empty")
    selected_units: dict[str, str] = {}
    used_units: set[str] = set()
    for target, (source, contract) in REQUIRED_TARGETS.items():
        artifact = _artifact_for_target(output, source, contract)
        candidates = [
            unit_hash
            for unit_hash, unit in compiler_units.items()
            if source in unit["sources"] and _selects_target(unit["settings"], source, contract)
        ]
        require(len(candidates) == 1, f"required target must select exactly one compiler input: {target}")
        unit_hash = candidates[0]
        _validate_metadata_against_unit(artifact, compiler_units[unit_hash], compiler_units[unit_hash]["sources"])
        selected_units[target] = unit_hash
        used_units.add(unit_hash)
    require(used_units == set(compiler_units), "selected compiler input is not used by a required target")

    closure = [
        {"logicalPath": path, "repositoryIdentity": identity, "sourceContentHash": source_hash}
        for path, (identity, source_hash) in sorted(sources.items())
    ]
    compiler_input = [compiler_units[key] for key in sorted(compiler_units)]
    unit_hash_bytes = [bytes.fromhex(value.removeprefix("0x")) for value in sorted(compiler_units)]
    source_closure_hash = keccak(SOURCE_CLOSURE_DOMAIN + canonical_json(closure), cast)
    compiler_input_hash = keccak(
        SOLC_INPUT_SET_DOMAIN + _length_prefixed(unit_hash_bytes),
        cast,
    )
    return {
        "sourceClosureHash": source_closure_hash,
        "compilerInputHash": compiler_input_hash,
        "sources": closure,
        "compilerUnitHashes": sorted(compiler_units),
        "compilerInputs": compiler_input,
        "selectedUnitMapping": dict(sorted(selected_units.items())),
        "capturedCompilerInputs": [path.name for path in capture_paths],
    }


def verify_source_closure(
    repo: Path, output: Path, build_info: Path, manifest: dict[str, Any], cast: str
) -> dict[str, Any]:
    evidence = calculate_source_closure(
        repo,
        output,
        build_info,
        manifest["build"]["sourceCommit"],
        cast,
    )
    require(
        evidence["sourceClosureHash"] == manifest["build"]["sourceClosureHash"],
        "source closure hash mismatch",
    )
    require(
        evidence["compilerInputHash"] == manifest["build"]["compilerInputHash"],
        "compiler input hash mismatch",
    )
    return evidence


def validate_uups_immutable(artifact: dict[str, Any]) -> list[dict[str, int]]:
    deployed = artifact.get("deployedBytecode", {})
    references = deployed.get("immutableReferences") or {}
    require(len(references) == 1, "implementation must contain only UUPS __self immutable")
    identifier, regions = next(iter(references.items()))
    require(len(regions) == 2, "unexpected UUPS __self reference count")
    require(all(region.get("length") == 32 for region in regions), "invalid UUPS immutable width")
    require(not deployed.get("linkReferences"), "implementation has unresolved library references")

    ir = artifact.get("ir", "")
    require(ir, "artifact IR is required to validate immutable provenance")
    set_ids = re.findall(r'setimmutable\([^,]+,\s*"([0-9]+)"', ir)
    load_matches = list(re.finditer(r'loadimmutable\("([0-9]+)"\)', ir))
    require(set(set_ids) == {identifier}, "unexpected immutable assignment in IR")
    require(load_matches and {match.group(1) for match in load_matches} == {identifier}, "unexpected immutable load")
    for match in load_matches:
        require('"__self"' in ir[max(0, match.start() - 180) : match.start()], "immutable is not UUPS __self")

    raw_metadata = json.loads(artifact.get("rawMetadata", "{}"))
    require(UUPS_SOURCE in raw_metadata.get("sources", {}), "canonical UUPS source is missing")
    return regions


def patched_runtime_hash(artifact: dict[str, Any], implementation: str, cast: str) -> str:
    require(re.fullmatch(r"0x[0-9a-fA-F]{40}", implementation) is not None, "invalid implementation address")
    regions = validate_uups_immutable(artifact)
    deployed = artifact["deployedBytecode"]["object"].removeprefix("0x")
    runtime = bytearray.fromhex(deployed)
    encoded_address = int(implementation, 16).to_bytes(32, "big")
    for region in regions:
        start = region["start"]
        end = start + region["length"]
        require(end <= len(runtime), "immutable reference is outside runtime bytecode")
        require(runtime[start:end] == bytes(32), "artifact immutable placeholder is not zero")
        runtime[start:end] = encoded_address
    return keccak(bytes(runtime), cast)


def verify(
    manifest_path: Path,
    output: Path,
    forge: str,
    cast: str,
    repo: Path | None = None,
    build_info: Path | None = None,
    foundry_config_hash: str | None = None,
) -> dict[str, Any]:
    raw_manifest = manifest_path.read_bytes()
    manifest = json.loads(raw_manifest)
    forge_output = command_output([forge, "--version"])
    validate_manifest(manifest, forge_output)
    cast_version, cast_commit = parse_toolchain(command_output([cast, "--version"]), "cast")
    require(cast_version == FOUNDRY_VERSION, "wrong cast version")
    require(cast_commit == FOUNDRY_COMMIT, "wrong cast commit")
    if foundry_config_hash is not None:
        require(foundry_config_hash == manifest["build"]["foundryConfigHash"], "Foundry config hash mismatch")
    contracts = manifest["contracts"]

    implementation_hashes: list[str] = []
    for index, contract in enumerate(CONTRACTS):
        artifact = artifact_at(output, contract)
        validate_metadata(artifact)
        codehash = patched_runtime_hash(artifact, contracts["implementations"][index], cast)
        require(
            codehash == contracts["implementationRuntimeCodehashes"][index].lower(),
            f"{contract} implementation runtime hash mismatch",
        )
        implementation_hashes.append(codehash)

    proxy = artifact_at(output, "ERC1967Proxy")
    validate_metadata(proxy)
    deployed = proxy.get("deployedBytecode", {})
    require(not deployed.get("immutableReferences"), "ERC1967Proxy contains an immutable")
    require(not deployed.get("linkReferences"), "ERC1967Proxy has unresolved library references")
    proxy_hash = keccak(bytes.fromhex(deployed["object"].removeprefix("0x")), cast)
    require(
        all(value.lower() == proxy_hash for value in contracts["proxyRuntimeCodehashes"]),
        "proxy runtime hash mismatch",
    )

    evidence = {
        "manifestHash": keccak(raw_manifest, cast),
        "sourceCommit": manifest["build"]["sourceCommit"],
        "build": manifest["build"],
        "proxyRuntimeCodehash": proxy_hash,
        "implementationRuntimeCodehashes": implementation_hashes,
        "usdc": manifest["external"]["usdc"],
    }
    if repo is not None:
        require(build_info is not None, "build-info directory is required")
        evidence["sourceProvenance"] = verify_source_closure(
            repo, output, build_info, manifest, cast
        )
    return evidence


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--forge", default="forge")
    parser.add_argument("--cast", default="cast")
    parser.add_argument("--build-info", type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    try:
        evidence = verify(
            args.manifest.resolve(),
            args.out.resolve(),
            args.forge,
            args.cast,
            build_info=args.build_info.resolve() if args.build_info else None,
        )
        rendered = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
        if args.evidence:
            args.evidence.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
    except (OSError, ValueError, json.JSONDecodeError, VerificationError) as error:
        raise SystemExit(f"release build verification failed: {error}") from error


if __name__ == "__main__":
    main()
