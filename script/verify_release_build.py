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
FOUNDRY_COMMIT = "b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2"
OUTCOME_SCHEMA = "uint256 paymentId,uint8 outcome"
CONFIRMATION_SCHEMA = "uint256 paymentId,uint8 confirmation"
UUPS_SOURCE = "lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol"


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
    value = command_output([cast, "keccak", "0x" + data.hex()]).lower()
    require(re.fullmatch(r"0x[0-9a-f]{64}", value) is not None, "cast returned an invalid hash")
    return value


def parse_toolchain(output: str, tool: str) -> tuple[str, str]:
    version = re.search(rf"^{tool} Version: (.+)$", output, re.MULTILINE)
    commit = re.search(r"^Commit SHA: ([0-9a-f]{40})$", output, re.MULTILINE)
    require(version is not None and commit is not None, f"unrecognized {tool} --version output")
    return version.group(1), commit.group(1)


def validate_manifest(manifest: dict[str, Any], forge_output: str) -> None:
    build = manifest.get("build", {})
    source_commit = build.get("sourceCommit", "")
    require(re.fullmatch(r"[0-9a-f]{40}", source_commit) is not None, "invalid source commit")
    require(source_commit != "0" * 40, "zero source commit")
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


def verify(manifest_path: Path, output: Path, forge: str, cast: str) -> dict[str, Any]:
    raw_manifest = manifest_path.read_bytes()
    manifest = json.loads(raw_manifest)
    forge_output = command_output([forge, "--version"])
    validate_manifest(manifest, forge_output)
    cast_version, cast_commit = parse_toolchain(command_output([cast, "--version"]), "cast")
    require(cast_version == FOUNDRY_VERSION, "wrong cast version")
    require(cast_commit == FOUNDRY_COMMIT, "wrong cast commit")
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

    return {
        "manifestHash": keccak(raw_manifest, cast),
        "sourceCommit": manifest["build"]["sourceCommit"],
        "build": manifest["build"],
        "proxyRuntimeCodehash": proxy_hash,
        "implementationRuntimeCodehashes": implementation_hashes,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--forge", default="forge")
    parser.add_argument("--cast", default="cast")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    try:
        evidence = verify(args.manifest.resolve(), args.out.resolve(), args.forge, args.cast)
        rendered = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
        if args.evidence:
            args.evidence.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
    except (OSError, ValueError, json.JSONDecodeError, VerificationError) as error:
        raise SystemExit(f"release build verification failed: {error}") from error


if __name__ == "__main__":
    main()
