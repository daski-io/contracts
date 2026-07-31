#!/usr/bin/env python3
"""Independently reproduce a reviewed release build without chain mutations."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path

import release_revision as revision_verifier
import verify_release_build as build_verifier
from release_build import (
    ReleaseError,
    build_release_targets,
    check_checkout,
    effective_foundry_config,
    hermetic_environment,
    output,
    require,
    validate_ambient_environment,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--release-ref", default="HEAD")
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8545")
    parser.add_argument("--revision", action="append", default=[], type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    forge = shutil.which("forge")
    cast = shutil.which("cast")
    require(forge is not None and cast is not None, "forge and cast must be on PATH")
    forge = str(Path(forge).resolve())
    cast = str(Path(cast).resolve())
    validate_ambient_environment(os.environ)
    repo = Path(output(["git", "rev-parse", "--show-toplevel"], Path.cwd())).resolve()
    manifest_path = args.manifest.resolve()
    evidence_dir = args.evidence_dir.resolve()
    require(manifest_path.is_file(), "release manifest does not exist")
    require(not evidence_dir.exists(), "reproduction evidence directory already exists")
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    forge_output = output([forge, "--version"], repo)
    cast_output = output([cast, "--version"], repo)
    build_verifier.validate_manifest(manifest, forge_output)
    check_checkout(repo, manifest, args.release_ref)

    with tempfile.TemporaryDirectory(prefix="daski-reproduction-") as temporary:
        temporary_root = Path(temporary)
        output_dir = temporary_root / "out"
        cache_dir = temporary_root / "cache"
        build_info_dir = temporary_root / "build-info"
        environment = hermetic_environment(temporary_root)
        foundry_config, foundry_config_hash = effective_foundry_config(
            repo, forge, cast, environment
        )
        build_release_targets(
            repo,
            forge,
            output_dir,
            cache_dir,
            build_info_dir,
            environment,
            temporary_root / "build.log",
        )
        local = build_verifier.verify(
            manifest_path,
            output_dir,
            forge,
            cast,
            repo=repo,
            build_info=build_info_dir,
            foundry_config_hash=foundry_config_hash,
        )
        revisions = revision_verifier.process(
            [path.resolve() for path in args.revision],
            temporary_root / "revisions",
            manifest_bytes,
            manifest,
            manifest["chainId"],
            args.rpc_url,
            cast,
            False,
        )
        revision_verifier.verify_inputs_unchanged(revisions, cast)
        require(manifest_path.read_bytes() == manifest_bytes, "release manifest changed during reproduction")
        check_checkout(repo, manifest, args.release_ref)

        evidence_dir.mkdir(parents=True)
        shutil.copyfile(manifest_path, evidence_dir / "release-manifest.json")
        shutil.copyfile(temporary_root / "build.log", evidence_dir / "build.log")
        shutil.copytree(build_info_dir, evidence_dir / "build-info")
        shutil.copytree(temporary_root / "revisions", evidence_dir / "revisions")
        evidence = {
            "schema": "daski-release-reproduction/v1",
            "manifestHash": local["manifestHash"],
            "sourceCommit": manifest["build"]["sourceCommit"],
            "forgeVersion": forge_output,
            "castVersion": cast_output,
            "foundryConfig": foundry_config,
            "foundryConfigHash": foundry_config_hash,
            "sourceProvenance": local["sourceProvenance"],
            "proxyRuntimeCodehash": local["proxyRuntimeCodehash"],
            "implementationRuntimeCodehashes": local["implementationRuntimeCodehashes"],
            "finalizedRevisionHashes": [
                revision["revisionHash"] for revision in revisions.finalized
            ],
            "effectiveReleaseHash": revisions.effective_release_hash,
        }
        (evidence_dir / "reproduction.json").write_text(
            json.dumps(evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(f"Release reproduction evidence: {evidence_dir}")


if __name__ == "__main__":
    try:
        main()
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        ReleaseError,
        build_verifier.VerificationError,
        revision_verifier.RevisionError,
    ) as error:
        raise SystemExit(f"release reproduction failed: {error}") from error
