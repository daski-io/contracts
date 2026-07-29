#!/usr/bin/env python3
"""Monitor the canonical identity proxy and trigger the pause-only guardian."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

from monitor_evidence import archive_alert, write_alert

IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
PAYMENT_ROUTER_INDEX = 4
PAUSE_ORDER = (4, 0, 1, 2, 3, 5, 6, 7, 8)


class MonitorError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MonitorError(message)


def command(arguments: list[str]) -> str:
    result = subprocess.run(arguments, check=False, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or f"{arguments[0]} failed")
    return result.stdout.strip()


def storage_address(value: str) -> str:
    require(
        value.startswith("0x") and len(value) == 66,
        "RPC returned an invalid storage word",
    )
    return "0x" + value[-40:]


def cast_string(value: str) -> str:
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        decoded = value
    require(isinstance(decoded, str), "RPC returned an invalid string")
    return decoded


def observe(identity: dict[str, Any], rpc_url: str, cast: str) -> dict[str, str]:
    proxy = identity["proxy"]
    implementation = storage_address(command([cast, "storage", proxy, IMPLEMENTATION_SLOT, "--rpc-url", rpc_url]))
    actual = {
        "proxy": proxy.lower(),
        "proxyRuntimeCodehash": command([cast, "codehash", proxy, "--rpc-url", rpc_url]).lower(),
        "implementation": implementation.lower(),
        "implementationRuntimeCodehash": command(
            [cast, "codehash", implementation, "--rpc-url", rpc_url]
        ).lower(),
        "erc1967Admin": storage_address(
            command([cast, "storage", proxy, ADMIN_SLOT, "--rpc-url", rpc_url])
        ).lower(),
    }
    if mismatches({field: identity[field] for field in actual}, actual):
        return actual
    try:
        actual["upgradeAuthority"] = command(
            [cast, "call", proxy, "owner()(address)", "--rpc-url", rpc_url]
        ).lower()
    except MonitorError as error:
        actual["upgradeAuthority"] = f"<read-failed: {error}>"
    try:
        actual["version"] = cast_string(
            command([cast, "call", proxy, "getVersion()(string)", "--rpc-url", rpc_url])
        )
    except MonitorError as error:
        actual["version"] = f"<read-failed: {error}>"
    return actual


def mismatches(expected: dict[str, Any], actual: dict[str, str]) -> dict[str, dict[str, str]]:
    differences: dict[str, dict[str, str]] = {}
    for field, expected_value in expected.items():
        actual_value = actual.get(field)
        normalized_expected = expected_value.lower() if field != "version" else expected_value
        if actual_value != normalized_expected:
            differences[field] = {"expected": expected_value, "actual": actual_value or ""}
    return differences


def pause_stack(
    proxies: list[str],
    rpc_url: str,
    effective_release_hash: str,
    guardian_command: Path,
    guardian_args: list[str],
    cast: str,
    transactions: list[dict[str, str]],
) -> None:
    selector = command([cast, "sig", "pauseExternalDependency()"])
    for index in PAUSE_ORDER:
        target = proxies[index]
        result = subprocess.run(
            [
                str(guardian_command),
                *guardian_args,
                "--target",
                target,
                "--calldata",
                selector,
                "--rpc-url",
                rpc_url,
                "--effective-release-hash",
                effective_release_hash,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        transaction = {
            "target": target,
            "guardianOutput": result.stdout.strip(),
            "guardianError": result.stderr.strip(),
            "submitted": str(result.returncode == 0).lower(),
            "confirmed": "false",
        }
        transactions.append(transaction)
        require(result.returncode == 0, result.stderr.strip() or f"guardian failed for {target}")
        paused = command(
            [cast, "call", target, "externalDependencyPaused()(bool)", "--rpc-url", rpc_url]
        ).lower()
        require(paused == "true", f"pause was not confirmed for {target}")
        transaction["confirmed"] = "true"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--release-summary", required=True, type=Path)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--interval-seconds", type=int, default=30)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--guardian-command", type=Path)
    parser.add_argument("--guardian-arg", action="append", default=[])
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    require(args.interval_seconds > 0 and args.interval_seconds <= 60, "poll interval must be 1-60 seconds")
    require(args.check_only or args.guardian_command is not None, "guardian command is required")
    cast = shutil.which("cast")
    require(cast is not None, "cast must be on PATH")
    cast = str(Path(cast).resolve())
    manifest_path = args.manifest.resolve()
    raw_manifest = manifest_path.read_bytes()
    manifest = json.loads(raw_manifest)
    expected = manifest["external"]["identityRegistry"]
    proxies = manifest["contracts"]["proxies"]
    require(len(proxies) == 9, "manifest must contain nine proxies")
    manifest_hash = command([cast, "keccak", "0x" + raw_manifest.hex()]).lower()
    summary = json.loads(args.release_summary.resolve().read_text(encoding="utf-8"))
    summary_manifest_hash = summary.get("manifestHash", "")
    require(
        isinstance(summary_manifest_hash, str) and summary_manifest_hash.lower() == manifest_hash,
        "release summary manifest mismatch",
    )
    effective_release_hash = summary.get("effectiveReleaseHash", "")
    require(
        re.fullmatch(r"0x[0-9a-fA-F]{64}", effective_release_hash) is not None,
        "invalid effective release hash",
    )

    while True:
        actual = observe(expected, args.rpc_url, cast)
        differences = mismatches(expected, actual)
        if differences:
            transactions: list[dict[str, str]] = []
            directory = archive_alert(
                args.evidence_dir.resolve(),
                effective_release_hash,
                manifest_hash,
                actual,
                differences,
                transactions,
            )
            if not args.check_only:
                guardian = args.guardian_command.resolve()
                require(guardian.is_file(), "guardian command does not exist")
                try:
                    pause_stack(
                        proxies,
                        args.rpc_url,
                        effective_release_hash,
                        guardian,
                        args.guardian_arg,
                        cast,
                        transactions,
                    )
                finally:
                    write_alert(
                        directory,
                        manifest_hash,
                        effective_release_hash,
                        actual,
                        differences,
                        transactions,
                    )
            raise MonitorError(f"external identity mismatch; evidence: {directory}")
        if args.once:
            return
        time.sleep(args.interval_seconds)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError, MonitorError) as error:
        raise SystemExit(f"identity monitor failed: {error}") from error
