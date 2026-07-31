#!/usr/bin/env python3
"""Trusted release entry point for verification and governance payloads."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import verify_release_build as build_verifier
import release_revision as revision_verifier
import verify_gateway_descriptor as gateway_verifier
from release_build import (
    ReleaseError,
    build_release_targets,
    check_checkout,
    effective_foundry_config,
    forge_script,
    hermetic_environment,
    output,
    require,
    runtime_environment,
    validate_ambient_environment,
)


def canonical_evidence(value: dict) -> bytes:
    return build_verifier.canonical_json(value) + b"\n"


def verify_run_inputs(
    repo: Path,
    manifest: dict,
    manifest_path: Path,
    manifest_bytes: bytes,
    pinned_manifest: Path,
    revision_evidence: revision_verifier.RevisionEvidence,
    revision_evidence_path: Path,
    revision_evidence_bytes: bytes,
    marker_path: Path,
    marker_bytes: bytes,
    release_ref: str,
    cast: str,
) -> None:
    check_checkout(repo, manifest, release_ref)
    require(manifest_path.read_bytes() == manifest_bytes, "release manifest changed during run")
    require(pinned_manifest.read_bytes() == manifest_bytes, "pinned release manifest changed during run")
    revision_verifier.verify_inputs_unchanged(revision_evidence, cast)
    require(
        revision_evidence_path.read_bytes() == revision_evidence_bytes,
        "canonical revision evidence changed during run",
    )
    require(marker_path.read_bytes() == marker_bytes, "release provenance marker changed during run")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=("verify", "accept", "guardian", "activate", "pause", "unpause", "revision-payload"),
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--release-ref", default="origin/develop")
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--active", action="store_true", help="verify the operational rather than dark state")
    parser.add_argument("--emit-only", action="store_true", help="emit a reviewed Safe payload without broadcasting")
    parser.add_argument("--revision", action="append", default=[], type=Path)
    parser.add_argument("--gateway-url")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    governance_modes = ("accept", "guardian", "activate", "pause", "unpause")
    require(not (args.mode == "verify" and args.emit_only), "--emit-only requires a governance mode")
    require(not (args.mode not in governance_modes and args.emit_only), "--emit-only requires a governance mode")
    require(not (args.mode != "verify" and args.active), "--active is only valid with verify")
    require(args.mode != "revision-payload" or args.revision, "revision-payload requires --revision")
    require(
        args.mode not in ("activate", "unpause") or args.gateway_url,
        "--gateway-url is required before enabling traffic",
    )
    forge = shutil.which("forge")
    cast = shutil.which("cast")
    require(forge is not None and cast is not None, "forge and cast must be on PATH")
    forge = str(Path(forge).resolve())
    cast = str(Path(cast).resolve())
    validate_ambient_environment(os.environ)

    repo = Path(output(["git", "rev-parse", "--show-toplevel"], Path.cwd())).resolve()
    manifest_path = args.manifest.resolve()
    evidence_root = args.evidence_dir.resolve()
    require(manifest_path.is_file(), "release manifest does not exist")
    try:
        evidence_root.relative_to(repo)
    except ValueError:
        pass
    else:
        raise ReleaseError("evidence directory must be outside the release checkout")

    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    forge_output = output([forge, "--version"], repo)
    cast_output = output([cast, "--version"], repo)
    build_verifier.validate_manifest(manifest, forge_output)
    head = check_checkout(repo, manifest, args.release_ref)

    with tempfile.TemporaryDirectory(prefix="daski-release-") as temporary:
        temporary_root = Path(temporary)
        pinned_manifest = temporary_root / "release-manifest.json"
        pinned_manifest.write_bytes(manifest_bytes)
        output_dir = temporary_root / "out"
        cache_dir = temporary_root / "cache"
        build_info_dir = temporary_root / "build-info"
        build_env = hermetic_environment(temporary_root)
        foundry_config, foundry_config_hash = effective_foundry_config(repo, forge, cast, build_env)
        build_release_targets(
            repo,
            forge,
            output_dir,
            cache_dir,
            build_info_dir,
            build_env,
            temporary_root / "build.log",
        )
        local_evidence = build_verifier.verify(
            pinned_manifest,
            output_dir,
            forge,
            cast,
            repo=repo,
            build_info=build_info_dir,
            foundry_config_hash=foundry_config_hash,
        )
        check_checkout(repo, manifest, args.release_ref)
        revision_evidence = revision_verifier.process(
            [path.resolve() for path in args.revision],
            temporary_root / "revisions",
            manifest_bytes,
            manifest,
            manifest["chainId"],
            args.rpc_url,
            cast,
            args.mode == "revision-payload",
        )
        revision_evidence_path = temporary_root / "revision-evidence.json"
        revision_evidence_bytes = canonical_evidence(
            {
                "baseManifestHash": local_evidence["manifestHash"],
                "effectiveReleaseHash": revision_evidence.effective_release_hash,
                "effectiveFacilitators": revision_evidence.effective_facilitators,
                "revisionHashes": [
                    revision["revisionHash"] for revision in revision_evidence.finalized
                ],
                "revisions": revision_evidence.finalized,
            }
        )
        revision_evidence_path.write_bytes(revision_evidence_bytes)
        revision_evidence_hash = build_verifier.keccak(revision_evidence_bytes, cast)
        run_id_bytes = secrets.token_bytes(32)
        require(any(run_id_bytes), "release run ID must be nonzero")
        run_id = "0x" + run_id_bytes.hex()
        marker = {
            "schema": "daski-release-provenance/v2",
            "runId": run_id,
            "manifestHash": local_evidence["manifestHash"],
            "revisionEvidenceHash": revision_evidence_hash,
            "effectiveReleaseHash": revision_evidence.effective_release_hash,
            "sourceClosureHash": local_evidence["sourceProvenance"]["sourceClosureHash"],
            "compilerInputHash": local_evidence["sourceProvenance"]["compilerInputHash"],
            "foundryConfigHash": foundry_config_hash,
        }
        marker_bytes = canonical_evidence(marker)
        provenance_path = temporary_root / "provenance.json"
        provenance_path.write_bytes(marker_bytes)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        action = f"{args.mode}-{'payload' if args.emit_only else 'execution'}"
        if args.mode == "verify":
            action = f"verify-{'active' if args.active else 'dark'}"
        evidence_key = revision_evidence.effective_release_hash
        if revision_evidence.proposal is not None:
            evidence_key = revision_evidence.proposal["revisionIntentHash"]
            action = "revision-payload"
        evidence_dir = evidence_root / evidence_key.removeprefix("0x") / f"{timestamp}-{action}"
        require(not evidence_dir.exists(), f"evidence run already exists: {evidence_dir}")
        evidence_dir.mkdir(parents=True)
        shutil.copyfile(pinned_manifest, evidence_dir / "release-manifest.json")
        shutil.copyfile(temporary_root / "build.log", evidence_dir / "build.log")
        shutil.copytree(build_info_dir, evidence_dir / "build-info")
        shutil.copytree(temporary_root / "revisions", evidence_dir / "revisions")
        shutil.copyfile(revision_evidence_path, evidence_dir / "revision-evidence.json")
        shutil.copyfile(provenance_path, evidence_dir / "provenance.json")
        (evidence_dir / "foundry-config.json").write_text(
            json.dumps(foundry_config, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        (evidence_dir / "local-build.json").write_text(
            json.dumps(local_evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        release_env = runtime_environment()
        release_env["RELEASE_MANIFEST_PATH"] = str(pinned_manifest)
        release_env["RELEASE_PROVENANCE_PATH"] = str(provenance_path)
        release_env["RELEASE_RUN_ID"] = run_id
        release_env["EFFECTIVE_RELEASE_HASH"] = revision_evidence.effective_release_hash
        release_env["RELEASE_REVISION_EVIDENCE_PATH"] = str(revision_evidence_path)

        def invoke_forge(script: str, log_name: str, broadcast: bool = False) -> None:
            verify_run_inputs(
                repo,
                manifest,
                manifest_path,
                manifest_bytes,
                pinned_manifest,
                revision_evidence,
                revision_evidence_path,
                revision_evidence_bytes,
                provenance_path,
                marker_bytes,
                args.release_ref,
                cast,
            )
            forge_script(
                repo,
                forge,
                script,
                args.rpc_url,
                output_dir,
                cache_dir,
                release_env,
                evidence_dir / log_name,
                broadcast=broadcast,
            )
            verify_run_inputs(
                repo,
                manifest,
                manifest_path,
                manifest_bytes,
                pinned_manifest,
                revision_evidence,
                revision_evidence_path,
                revision_evidence_bytes,
                provenance_path,
                marker_bytes,
                args.release_ref,
                cast,
            )

        def verify_gateway() -> None:
            descriptor = gateway_verifier.load_url(args.gateway_url)
            gateway_verifier.verify(manifest, descriptor)

        if args.mode == "revision-payload":
            release_env["DEPLOYMENT_ACTIVE"] = "true"
            release_env["EXTERNAL_DEPENDENCY_PAUSED"] = "false"
            invoke_forge("script/VerifyDeployment.s.sol", "pre-proposal-verification.log")
            (evidence_dir / "revision-payload.json").write_text(
                json.dumps(revision_evidence.proposal, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        elif args.mode == "verify":
            release_env["DEPLOYMENT_ACTIVE"] = str(args.active).lower()
            invoke_forge("script/VerifyDeployment.s.sol", "verification.log")
        else:
            if args.mode in ("activate", "unpause"):
                verify_gateway()
                release_env["DEPLOYMENT_ACTIVE"] = str(args.mode == "unpause").lower()
                release_env["EXTERNAL_DEPENDENCY_PAUSED"] = str(args.mode == "unpause").lower()
                invoke_forge("script/VerifyDeployment.s.sol", "pre-activation.log")
            release_env["GOVERNANCE_BATCH"] = args.mode
            release_env["EMIT_ONLY"] = str(args.emit_only).lower()
            if args.emit_only:
                require("GOVERNANCE_SENDER" in release_env, "GOVERNANCE_SENDER is required with --emit-only")
            if args.mode in ("activate", "unpause"):
                verify_gateway()
            invoke_forge(
                "script/ExecuteGovernanceBatches.s.sol",
                f"{args.mode}-batch.log",
                broadcast=not args.emit_only,
            )
            if not args.emit_only and args.mode != "guardian":
                release_env["DEPLOYMENT_ACTIVE"] = str(args.mode in ("activate", "pause", "unpause")).lower()
                release_env["EXTERNAL_DEPENDENCY_PAUSED"] = str(args.mode == "pause").lower()
                invoke_forge("script/VerifyDeployment.s.sol", "post-execution.log")

        verify_run_inputs(
            repo,
            manifest,
            manifest_path,
            manifest_bytes,
            pinned_manifest,
            revision_evidence,
            revision_evidence_path,
            revision_evidence_bytes,
            provenance_path,
            marker_bytes,
            args.release_ref,
            cast,
        )
        summary = {
            "mode": args.mode,
            "emitOnly": args.emit_only,
            "manifestHash": local_evidence["manifestHash"],
            "sourceCommit": head,
            "releaseRef": args.release_ref,
            "forgePath": forge,
            "castPath": cast,
            "forgeVersion": forge_output,
            "castVersion": cast_output,
            "sourceClosureHash": local_evidence["sourceProvenance"]["sourceClosureHash"],
            "compilerInputHash": local_evidence["sourceProvenance"]["compilerInputHash"],
            "foundryConfigHash": foundry_config_hash,
            "runId": run_id,
            "revisionEvidenceHash": revision_evidence_hash,
            "effectiveReleaseHash": revision_evidence.effective_release_hash,
            "effectiveFacilitators": revision_evidence.effective_facilitators,
            "revisions": revision_evidence.finalized,
        }
        (evidence_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print(f"Release evidence: {evidence_dir}")


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
        raise SystemExit(f"release failed: {error}") from error
