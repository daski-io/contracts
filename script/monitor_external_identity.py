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

from monitor_evidence import archive_alert, write_alert
from monitor_identity_chain import (
    block_number,
    mismatches,
    next_cursor_block,
    observe,
    scan_identity_events,
    storage_address,
    write_cursor,
)

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


def notify(
    alert_command: Path,
    alert_args: list[str],
    evidence_dir: Path,
    effective_release_hash: str,
    manifest_hash: str,
) -> dict[str, str]:
    result = subprocess.run(
        [
            str(alert_command),
            *alert_args,
            "--evidence-dir",
            str(evidence_dir),
            "--effective-release-hash",
            effective_release_hash,
            "--manifest-hash",
            manifest_hash,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    evidence = {
        "command": str(alert_command),
        "output": result.stdout.strip(),
        "error": result.stderr.strip(),
        "submitted": str(result.returncode == 0).lower(),
    }
    require(result.returncode == 0, result.stderr.strip() or "alert command failed")
    return evidence


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--release-summary", required=True, type=Path)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--cursor-file", type=Path)
    parser.add_argument("--interval-seconds", type=int, default=30)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--guardian-command", type=Path)
    parser.add_argument("--guardian-arg", action="append", default=[])
    parser.add_argument("--alert-command", type=Path)
    parser.add_argument("--alert-arg", action="append", default=[])
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    require(args.interval_seconds > 0 and args.interval_seconds <= 60, "poll interval must be 1-60 seconds")
    require(args.check_only or args.guardian_command is not None, "guardian command is required")
    require(args.check_only or args.alert_command is not None, "alert command is required")
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
    cursor_file = (
        args.cursor_file.resolve()
        if args.cursor_file
        else args.evidence_dir.resolve() / "external-identity-cursor.json"
    )

    while True:
        try:
            observed_block = block_number(args.rpc_url, cast, command)
            actual = observe(
                expected,
                args.rpc_url,
                cast,
                command,
                observed_block,
            )
            cursor_start = next_cursor_block(
                cursor_file,
                expected["proxy"],
                manifest_hash,
                observed_block,
            )
            require(
                cursor_start <= observed_block + 1,
                "identity event cursor is ahead of the observed chain",
            )
            events = scan_identity_events(
                expected["proxy"],
                cursor_start,
                observed_block,
                args.rpc_url,
                cast,
                command,
            )
        except (MonitorError, OSError, ValueError, json.JSONDecodeError) as error:
            actual = {"rpcError": str(error)}
            differences = {
                "rpcRead": {
                    "expected": "successful pinned observation",
                    "actual": str(error),
                }
            }
            directory = archive_alert(
                args.evidence_dir.resolve(),
                effective_release_hash,
                manifest_hash,
                actual,
                differences,
                [],
            )
            if not args.check_only:
                alert_command = args.alert_command.resolve()
                require(alert_command.is_file(), "alert command does not exist")
                alert = notify(
                    alert_command,
                    args.alert_arg,
                    directory,
                    effective_release_hash,
                    manifest_hash,
                )
                write_alert(
                    directory,
                    manifest_hash,
                    effective_release_hash,
                    actual,
                    differences,
                    [],
                    alert,
                )
            if args.once:
                raise MonitorError(
                    f"external identity observation failed; evidence: {directory}"
                ) from error
            time.sleep(args.interval_seconds)
            continue

        differences = mismatches(expected, actual)
        if events:
            actual["identityEvents"] = json.dumps(events, sort_keys=True)
            differences["identityEvents"] = {
                "expected": "none",
                "actual": actual["identityEvents"],
            }
        if differences:
            transactions: list[dict[str, str]] = []
            alert: dict[str, str] | None = None
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
                    alert_command = args.alert_command.resolve()
                    require(alert_command.is_file(), "alert command does not exist")
                    try:
                        alert = notify(
                            alert_command,
                            args.alert_arg,
                            directory,
                            effective_release_hash,
                            manifest_hash,
                        )
                    finally:
                        write_alert(
                            directory,
                            manifest_hash,
                            effective_release_hash,
                            actual,
                            differences,
                            transactions,
                            alert,
                        )
            raise MonitorError(f"external identity mismatch; evidence: {directory}")
        write_cursor(
            cursor_file,
            expected["proxy"],
            manifest_hash,
            observed_block,
        )
        if args.once:
            return
        time.sleep(args.interval_seconds)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError, MonitorError) as error:
        raise SystemExit(f"identity monitor failed: {error}") from error
