#!/usr/bin/env python3
"""Trusted release entry point for verification and governance payloads."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import verify_release_build as build_verifier


class ReleaseError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def output(command: list[str], cwd: Path) -> str:
    result = subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or f"{command[0]} failed")
    return result.stdout.strip()


def run_logged(command: list[str], cwd: Path, env: dict[str, str], log_path: Path) -> None:
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
        require(process.wait() == 0, f"{command[0]} failed; see {log_path}")


def check_checkout(repo: Path, manifest: dict, release_ref: str) -> str:
    status = output(["git", "status", "--porcelain=v1", "--untracked-files=all"], repo)
    require(not status, f"release checkout is dirty:\n{status}")
    head = output(["git", "rev-parse", "HEAD"], repo)
    require(head == manifest["build"]["sourceCommit"], "HEAD does not equal build.sourceCommit")
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", head, release_ref],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    require(ancestor.returncode == 0, f"{release_ref} does not contain HEAD")
    submodules = output(["git", "submodule", "status", "--recursive"], repo)
    bad = [line for line in submodules.splitlines() if line and not line.startswith(" ")]
    require(not bad, "submodule commit does not match its recorded gitlink")
    require((repo / "foundry.lock").is_file(), "foundry.lock is missing")
    require(not (repo / "out").exists() and not (repo / "cache").exists(), "stale build output exists")
    return head


def forge_script(
    repo: Path,
    forge: str,
    script: str,
    rpc_url: str,
    output_dir: Path,
    cache_dir: Path,
    env: dict[str, str],
    log_path: Path,
    broadcast: bool = False,
) -> None:
    command = [
        forge,
        "script",
        script,
        "--rpc-url",
        rpc_url,
        "--out",
        str(output_dir),
        "--cache-path",
        str(cache_dir),
    ]
    if broadcast:
        command.append("--broadcast")
    run_logged(command, repo, env, log_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("verify", "accept", "activate"))
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--release-ref", default="origin/develop")
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--active", action="store_true", help="verify the operational rather than dark state")
    parser.add_argument("--emit-only", action="store_true", help="emit a reviewed Safe payload without broadcasting")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    require(not (args.mode == "verify" and args.emit_only), "--emit-only requires accept or activate")
    require(not (args.mode != "verify" and args.active), "--active is only valid with verify")
    forge = shutil.which("forge")
    cast = shutil.which("cast")
    require(forge is not None and cast is not None, "forge and cast must be on PATH")

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
    build_verifier.validate_manifest(manifest, forge_output)
    head = check_checkout(repo, manifest, args.release_ref)

    with tempfile.TemporaryDirectory(prefix="daski-release-") as temporary:
        temporary_root = Path(temporary)
        pinned_manifest = temporary_root / "release-manifest.json"
        pinned_manifest.write_bytes(manifest_bytes)
        output_dir = temporary_root / "out"
        cache_dir = temporary_root / "cache"
        run_logged(
            [
                forge,
                "build",
                "src",
                "script/Deploy.s.sol",
                "--force",
                "--out",
                str(output_dir),
                "--cache-path",
                str(cache_dir),
            ],
            repo,
            os.environ.copy(),
            temporary_root / "build.log",
        )
        local_evidence = build_verifier.verify(pinned_manifest, output_dir, forge, cast)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        action = f"{args.mode}-{'payload' if args.emit_only else 'execution'}"
        if args.mode == "verify":
            action = f"verify-{'active' if args.active else 'dark'}"
        evidence_dir = evidence_root / local_evidence["manifestHash"].removeprefix("0x") / f"{timestamp}-{action}"
        require(not evidence_dir.exists(), f"evidence run already exists: {evidence_dir}")
        evidence_dir.mkdir(parents=True)
        shutil.copyfile(pinned_manifest, evidence_dir / "release-manifest.json")
        shutil.copyfile(temporary_root / "build.log", evidence_dir / "build.log")
        (evidence_dir / "local-build.json").write_text(
            json.dumps(local_evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        release_env = os.environ.copy()
        release_env["RELEASE_MANIFEST_PATH"] = str(evidence_dir / "release-manifest.json")

        if args.mode == "verify":
            release_env["DEPLOYMENT_ACTIVE"] = str(args.active).lower()
            forge_script(
                repo,
                forge,
                "script/VerifyDeployment.s.sol",
                args.rpc_url,
                output_dir,
                cache_dir,
                release_env,
                evidence_dir / "verification.log",
            )
        else:
            if args.mode == "activate":
                release_env["DEPLOYMENT_ACTIVE"] = "false"
                forge_script(
                    repo,
                    forge,
                    "script/VerifyDeployment.s.sol",
                    args.rpc_url,
                    output_dir,
                    cache_dir,
                    release_env,
                    evidence_dir / "pre-activation.log",
                )
            release_env["GOVERNANCE_BATCH"] = args.mode
            release_env["EMIT_ONLY"] = str(args.emit_only).lower()
            if args.emit_only:
                require("GOVERNANCE_SENDER" in release_env, "GOVERNANCE_SENDER is required with --emit-only")
            forge_script(
                repo,
                forge,
                "script/ExecuteGovernanceBatches.s.sol",
                args.rpc_url,
                output_dir,
                cache_dir,
                release_env,
                evidence_dir / f"{args.mode}-batch.log",
                broadcast=not args.emit_only,
            )
            if not args.emit_only:
                release_env["DEPLOYMENT_ACTIVE"] = str(args.mode == "activate").lower()
                forge_script(
                    repo,
                    forge,
                    "script/VerifyDeployment.s.sol",
                    args.rpc_url,
                    output_dir,
                    cache_dir,
                    release_env,
                    evidence_dir / "post-execution.log",
                )

        summary = {
            "mode": args.mode,
            "emitOnly": args.emit_only,
            "manifestHash": local_evidence["manifestHash"],
            "sourceCommit": head,
            "releaseRef": args.release_ref,
        }
        (evidence_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print(f"Release evidence: {evidence_dir}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, ReleaseError, build_verifier.VerificationError) as error:
        raise SystemExit(f"release failed: {error}") from error
