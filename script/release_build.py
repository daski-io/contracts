"""Hermetic checkout, environment, and Foundry execution helpers."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

import verify_release_build as build_verifier

DANGEROUS_BUILD_PREFIXES = ("FOUNDRY_", "DAPP_", "SOLC_")
FORBIDDEN_RELEASE_ENVIRONMENT = {"RELEASE_E2E_LOCAL_FIXTURE"}
REMAPPING_LOCK = Path("script/release-remappings.lock")
SOLC_CAPTURE = Path("script/solc_capture.py")
SOLC_VERSION = "0.8.24"


class ReleaseError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def output(command: list[str], cwd: Path) -> str:
    result = subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or f"{command[0]} failed")
    return result.stdout.strip()


def validate_ambient_environment(environment: dict[str, str]) -> None:
    unsafe = sorted(
        name
        for name in environment
        if name.startswith(DANGEROUS_BUILD_PREFIXES) or name in FORBIDDEN_RELEASE_ENVIRONMENT
    )
    require(not unsafe, f"unsafe build environment variables: {', '.join(unsafe)}")


def hermetic_environment(temporary_root: Path) -> dict[str, str]:
    isolated_home = temporary_root / "home"
    isolated_home.mkdir()
    environment = {
        "HOME": str(isolated_home),
        "PATH": os.environ.get("PATH", os.defpath),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
    }
    svm_home = Path.home() / ".svm"
    if svm_home.is_dir():
        environment["SVM_HOME"] = str(svm_home)
    return environment


def runtime_environment() -> dict[str, str]:
    return {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(DANGEROUS_BUILD_PREFIXES)
    }


def effective_foundry_config(
    repo: Path, forge: str, cast: str, environment: dict[str, str]
) -> tuple[dict, str]:
    result = subprocess.run(
        [
            forge,
            "config",
            "--json",
            "--root",
            str(repo),
            "--config-path",
            str(repo / "foundry.toml"),
        ],
        cwd=repo,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0, result.stderr.strip() or "forge config failed")
    config = json.loads(result.stdout)
    locked = [
        line.strip()
        for line in (repo / REMAPPING_LOCK).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    require(config.get("remappings") == locked, "effective remappings do not match release lock")
    canonical = {
        "src": config.get("src"),
        "libs": config.get("libs"),
        "solc": config.get("solc"),
        "evm_version": config.get("evm_version"),
        "via_ir": config.get("via_ir"),
        "optimizer": config.get("optimizer"),
        "optimizer_runs": config.get("optimizer_runs"),
        "extra_output": config.get("extra_output"),
        "remappings": locked,
    }
    return canonical, build_verifier.keccak(build_verifier.canonical_json(canonical), cast)


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


def build_release_targets(
    repo: Path,
    forge: str,
    output_dir: Path,
    cache_dir: Path,
    build_info_dir: Path,
    environment: dict[str, str],
    log_path: Path,
) -> None:
    compiler = _resolve_solc()
    capture_dir = build_info_dir / "compiler-inputs"
    capture_environment = dict(environment)
    capture_environment["DASKI_REAL_COMPILER"] = str(compiler)
    capture_environment["DASKI_COMPILER_INPUT_DIR"] = str(capture_dir)
    run_logged(
        [
            forge,
            "build",
            "src",
            "script/Deploy.s.sol",
            "script/VerifyDeployment.s.sol",
            "script/ExecuteGovernanceBatches.s.sol",
            "--use",
            str(repo / SOLC_CAPTURE),
            "--force",
            "--out",
            str(output_dir),
            "--cache-path",
            str(cache_dir),
            "--build-info",
            "--build-info-path",
            str(build_info_dir),
            "--root",
            str(repo),
            "--config-path",
            str(repo / "foundry.toml"),
        ],
        repo,
        capture_environment,
        log_path,
    )
    require(any(capture_dir.glob("*.json")), "solc compiler input capture is empty")


def _resolve_solc() -> Path:
    candidate = Path.home() / ".svm" / SOLC_VERSION / f"solc-{SOLC_VERSION}"
    require(candidate.is_file(), f"pinned solc is missing: {candidate}")
    result = subprocess.run(
        [candidate, "--version"],
        check=False,
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0, result.stderr.strip() or "solc version check failed")
    require(
        re.search(r"Version: 0\.8\.24\+commit\.e11b9ed9", result.stdout) is not None,
        "wrong pinned solc version",
    )
    return candidate.resolve()


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
    submodule_result = subprocess.run(
        ["git", "submodule", "status", "--recursive"],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    require(submodule_result.returncode == 0, submodule_result.stderr.strip() or "git submodule status failed")
    bad = [line for line in submodule_result.stdout.splitlines() if line and not line.startswith(" ")]
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
        "--root",
        str(repo),
        "--config-path",
        str(repo / "foundry.toml"),
    ]
    if broadcast:
        command.append("--broadcast")
    run_logged(command, repo, env, log_path)
