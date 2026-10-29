#!/usr/bin/env python3
"""Export the exact build of the upgradeable implementations for releases.

The release engine (daski-io/deploy-mainnet) deploys an implementation from
these bytes through the governance Safe and verifies the deployed code against
them, so a release never rebuilds a contract. CI uploads the export of every
build as the contract-build-<commit> artifact.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


CONTRACTS = (
    "AgentIndex",
    "ProviderRegistry",
    "ServiceRegistry",
    "ValidationRegistry",
    "ReputationStorage",
)

ABI_CONTRACTS = (*CONTRACTS, "OutcomeSplitter", "OutcomeSplitterFactory")


def export_abis(out: Path, target: Path) -> None:
    """Read the compiled ABI without changing Forge's compiler output selection."""
    abis = {}
    for name in ABI_CONTRACTS:
        artifact = json.loads((out / f"{name}.sol" / f"{name}.json").read_text(encoding="utf-8"))
        abi = artifact["abi"]
        if not isinstance(abi, list) or not abi:
            raise SystemExit(f"{name}: expected a non-empty ABI array")
        abis[name] = abi
    target.mkdir(parents=True, exist_ok=True)
    for name, abi in abis.items():
        (target / f"{name}.json").write_text(json.dumps(abi) + "\n", encoding="utf-8")
        print(f"{name}: {len(abi)} ABI entries")


def export(out: Path, target: Path, commit: str) -> dict:
    if len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
        raise SystemExit("an exact 40-character commit is required")
    target.mkdir(parents=True, exist_ok=True)
    manifest = {"schemaVersion": 1, "commit": commit, "contracts": {}}
    for name in CONTRACTS:
        artifact = json.loads((out / f"{name}.sol" / f"{name}.json").read_text(encoding="utf-8"))
        creation, runtime = artifact["bytecode"], artifact["deployedBytecode"]
        if creation.get("linkReferences") or runtime.get("linkReferences"):
            raise SystemExit(f"{name}: linked libraries are not supported")
        entry = {
            "contractName": name,
            "compiler": artifact["metadata"]["compiler"]["version"],
            "abi": artifact["abi"],
            "bytecode": creation["object"],
            "deployedBytecode": runtime["object"],
            "immutableReferences": runtime.get("immutableReferences", {}),
        }
        for key in ("bytecode", "deployedBytecode"):
            if not entry[key].startswith("0x") or len(entry[key]) < 4:
                raise SystemExit(f"{name}: {key} is empty")
        (target / f"{name}.json").write_text(json.dumps(entry) + "\n", encoding="utf-8")
        manifest["contracts"][name] = {"compiler": entry["compiler"], "file": f"{name}.json"}
    (target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="out", type=Path, help="forge build output")
    parser.add_argument("--target", default="build-export", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--abi-target", type=Path, help="also export the seven public ABIs")
    args = parser.parse_args()
    manifest = export(args.out, args.target, args.commit)
    if args.abi_target is not None:
        export_abis(args.out, args.abi_target)
    for name in manifest["contracts"]:
        print(f"{name}: exported")


if __name__ == "__main__":
    main()
