#!/usr/bin/env python3
"""Produce the reproducible build fields for a draft release manifest."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path

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
    parser.add_argument("--release-ref", default="origin/develop")
    parser.add_argument("--output", type=Path)
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
    head = output(["git", "rev-parse", "HEAD"], repo)
    check_checkout(repo, {"build": {"sourceCommit": head}}, args.release_ref)
    forge_output = output([forge, "--version"], repo)
    foundry_version, foundry_commit = build_verifier.parse_toolchain(forge_output, "forge")
    require(foundry_version == build_verifier.FOUNDRY_VERSION, "wrong Foundry version")
    require(foundry_commit == build_verifier.FOUNDRY_COMMIT, "wrong Foundry commit")
    cast_version, cast_commit = build_verifier.parse_toolchain(output([cast, "--version"], repo), "cast")
    require(cast_version == build_verifier.FOUNDRY_VERSION, "wrong cast version")
    require(cast_commit == build_verifier.FOUNDRY_COMMIT, "wrong cast commit")

    with tempfile.TemporaryDirectory(prefix="daski-build-profile-") as temporary:
        temporary_root = Path(temporary)
        output_dir = temporary_root / "out"
        build_env = hermetic_environment(temporary_root)
        _, foundry_config_hash = effective_foundry_config(repo, forge, cast, build_env)
        build_release_targets(
            repo,
            forge,
            output_dir,
            temporary_root / "cache",
            temporary_root / "build-info",
            build_env,
            temporary_root / "build.log",
        )
        provenance = build_verifier.calculate_source_closure(
            repo,
            output_dir,
            temporary_root / "build-info",
            head,
            cast,
        )
        check_checkout(repo, {"build": {"sourceCommit": head}}, args.release_ref)

    profile = {
        "sourceCommit": head,
        "sourceClosureHash": provenance["sourceClosureHash"],
        "compilerInputHash": provenance["compilerInputHash"],
        "foundryConfigHash": foundry_config_hash,
        "solcVersion": build_verifier.SOLC_VERSION,
        "optimizer": True,
        "optimizerRuns": 200,
        "viaIr": True,
        "evmVersion": build_verifier.EVM_VERSION,
        "foundryVersion": foundry_version,
        "foundryCommit": foundry_commit,
    }
    result = json.dumps({"build": profile}, indent=2) + "\n"
    if args.output is not None:
        destination = args.output.resolve()
        try:
            destination.relative_to(repo)
        except ValueError:
            pass
        else:
            raise ReleaseError("build profile output must be outside the release checkout")
        destination.write_text(result, encoding="utf-8")
    print(result, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, ReleaseError, build_verifier.VerificationError) as error:
        raise SystemExit(f"release build preparation failed: {error}") from error
