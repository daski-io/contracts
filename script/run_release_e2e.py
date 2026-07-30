#!/usr/bin/env python3
"""Run the release ceremony against an isolated local Anvil chain."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

from release_build import ReleaseError, output, require


EXPECTED_EVIDENCE_ROOT = Path("/tmp/daski-release-e2e")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--anvil-log", type=Path)
    return parser.parse_args()


def run_logged(command: list[str], repo: Path, environment: dict[str, str], log_path: Path) -> None:
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=repo,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
        require(process.wait() == 0, f"{command[0]} failed; see {log_path}")


def main() -> None:
    args = parse_args()
    forge = shutil.which("forge")
    cast = shutil.which("cast")
    require(forge is not None and cast is not None, "forge and cast must be on PATH")
    repo = Path(output(["git", "rev-parse", "--show-toplevel"], Path.cwd())).resolve()
    evidence_root = args.evidence_dir.resolve()
    require(evidence_root == EXPECTED_EVIDENCE_ROOT, f"evidence directory must be {EXPECTED_EVIDENCE_ROOT}")
    require(not evidence_root.exists(), "release E2E evidence directory already exists")
    require(not (repo / "out").exists() and not (repo / "cache").exists(), "release E2E checkout has stale output")
    require(not output(["git", "status", "--porcelain=v1", "--untracked-files=all"], repo), "release E2E checkout is dirty")
    require(output([cast, "chain-id", "--rpc-url", args.rpc_url], repo) == "31337", "Anvil chain ID must be 31337")

    evidence_root.mkdir()
    build_profile = evidence_root / "build-profile.json"
    prepare_log = evidence_root / "build-profile.log"
    environment = dict(os.environ)
    environment.pop("RELEASE_E2E_LOCAL_FIXTURE", None)
    run_logged(
        [
            "python3",
            "script/prepare_release_build.py",
            "--release-ref",
            "HEAD",
            "--output",
            str(build_profile),
        ],
        repo,
        environment,
        prepare_log,
    )

    test_environment = dict(environment)
    test_environment["E2E_BUILD_PROFILE_PATH"] = str(build_profile)
    test_environment["E2E_EVIDENCE_DIR"] = str(evidence_root)
    ceremony_log = evidence_root / "ceremony.log"
    run_logged(
        [
            forge,
            "test",
            "--match-path",
            "test/ReleaseCeremonyE2E.t.sol",
            "--fork-url",
            args.rpc_url,
            "--out",
            str(evidence_root / "forge-out"),
            "--cache-path",
            str(evidence_root / "forge-cache"),
            "-vvv",
        ],
        repo,
        test_environment,
        ceremony_log,
    )

    summaries = list(evidence_root.glob("0x*/ceremony-summary.json"))
    require(len(summaries) == 1, "release ceremony did not archive one final evidence set")
    final_directory = summaries[0].parent
    summary = json.loads(summaries[0].read_text(encoding="utf-8"))
    require(summary.get("emitOnlyAndExecutionCovered") is True, "governance branch coverage missing")
    require(summary.get("revisionProposalGenerated") is True, "facilitator revision proposal missing")
    require(summary.get("finalizedRevisionVerified") is True, "finalized facilitator revision missing")
    require(summary.get("finalFacilitatorSetVerified") is True, "final facilitator verification missing")
    shutil.copyfile(build_profile, final_directory / "build-profile.json")
    shutil.copyfile(prepare_log, final_directory / "build-profile.log")
    shutil.copyfile(ceremony_log, final_directory / "ceremony.log")
    if args.anvil_log is not None:
        shutil.copyfile(args.anvil_log.resolve(), final_directory / "anvil.log")
    (final_directory / "runner-summary.json").write_text(
        json.dumps(
            {
                "schema": "daski-release-e2e-runner/v1",
                "sourceCommit": output(["git", "rev-parse", "HEAD"], repo),
                "chainId": 31337,
                "cleanClone": True,
                "repositoryOutAndCacheAbsent": not (repo / "out").exists() and not (repo / "cache").exists(),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    require(not output(["git", "status", "--porcelain=v1", "--untracked-files=all"], repo), "release E2E mutated checkout")
    print(f"Release ceremony evidence: {final_directory}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, ReleaseError) as error:
        raise SystemExit(f"release E2E failed: {error}") from error
