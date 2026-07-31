"""Pinned identity-registry observations and upgrade-event cursor handling."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable

IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
EVENT_TOPICS = {
    "0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b": "Upgraded",
    "0x7e644d79422f17c01e4894b5f4f588d331ebfa28653d42ae832dc59e38c9798f": "AdminChanged",
    "0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0": "OwnershipTransferred",
}

Runner = Callable[[list[str]], str]


def storage_address(value: str) -> str:
    if not value.startswith("0x") or len(value) != 66:
        raise ValueError("RPC returned an invalid storage word")
    return "0x" + value[-40:]


def cast_string(value: str) -> str:
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        decoded = value
    if not isinstance(decoded, str):
        raise ValueError("RPC returned an invalid string")
    return decoded


def mismatches(
    expected: dict[str, Any],
    actual: dict[str, str],
) -> dict[str, dict[str, str]]:
    differences: dict[str, dict[str, str]] = {}
    for field, expected_value in expected.items():
        actual_value = actual.get(field)
        normalized_expected = (
            expected_value.lower() if field != "version" else expected_value
        )
        if actual_value != normalized_expected:
            differences[field] = {
                "expected": expected_value,
                "actual": actual_value or "",
            }
    return differences


def block_number(rpc_url: str, cast: str, run: Runner) -> int:
    return int(run([cast, "block-number", "--rpc-url", rpc_url]), 0)


def observe(
    identity: dict[str, Any],
    rpc_url: str,
    cast: str,
    run: Runner,
    block: int,
) -> dict[str, str]:
    proxy = identity["proxy"]
    pinned = ["--block", str(block), "--rpc-url", rpc_url]
    implementation = storage_address(
        run([cast, "storage", proxy, IMPLEMENTATION_SLOT, *pinned])
    )
    actual = {
        "proxy": proxy.lower(),
        "observedBlock": str(block),
        "proxyRuntimeCodehash": run(
            [cast, "codehash", proxy, *pinned]
        ).lower(),
        "implementation": implementation.lower(),
        "implementationRuntimeCodehash": run(
            [cast, "codehash", implementation, *pinned]
        ).lower(),
        "erc1967Admin": storage_address(
            run([cast, "storage", proxy, ADMIN_SLOT, *pinned])
        ).lower(),
    }
    comparable_expected = {
        field: identity[field] for field in actual if field in identity
    }
    if mismatches(comparable_expected, actual):
        return actual
    actual["upgradeAuthority"] = run(
        [cast, "call", proxy, "owner()(address)", *pinned]
    ).lower()
    actual["version"] = cast_string(
        run([cast, "call", proxy, "getVersion()(string)", *pinned])
    )
    return actual


def scan_identity_events(
    proxy: str,
    from_block: int,
    to_block: int,
    rpc_url: str,
    cast: str,
    run: Runner,
) -> list[dict[str, Any]]:
    if from_block > to_block:
        return []
    event_filter = {
        "address": proxy,
        "fromBlock": hex(from_block),
        "toBlock": hex(to_block),
        "topics": [list(EVENT_TOPICS)],
    }
    raw = json.loads(
        run(
            [
                cast,
                "rpc",
                "eth_getLogs",
                json.dumps(event_filter, separators=(",", ":")),
                "--rpc-url",
                rpc_url,
            ]
        )
    )
    if not isinstance(raw, list):
        raise ValueError("RPC returned invalid identity event logs")
    events: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            raise ValueError("RPC returned an invalid identity event")
        topics = entry.get("topics")
        if not isinstance(topics, list) or not topics:
            raise ValueError("RPC identity event has no topic")
        topic = str(topics[0]).lower()
        events.append({**entry, "event": EVENT_TOPICS.get(topic, "Unknown")})
    return events


def next_cursor_block(
    cursor_file: Path,
    proxy: str,
    manifest_hash: str,
    default_block: int,
) -> int:
    if not cursor_file.exists():
        return default_block
    cursor = json.loads(cursor_file.read_text(encoding="utf-8"))
    if (
        cursor.get("proxy", "").lower() != proxy.lower()
        or cursor.get("manifestHash", "").lower() != manifest_hash.lower()
    ):
        raise ValueError("identity event cursor does not match this release")
    last_scanned = cursor.get("lastScannedBlock")
    if not isinstance(last_scanned, int) or last_scanned < 0:
        raise ValueError("identity event cursor is invalid")
    return last_scanned + 1


def write_cursor(
    cursor_file: Path,
    proxy: str,
    manifest_hash: str,
    last_scanned_block: int,
) -> None:
    cursor_file.parent.mkdir(parents=True, exist_ok=True)
    temporary = cursor_file.with_suffix(cursor_file.suffix + ".tmp")
    temporary.write_text(
        json.dumps(
            {
                "proxy": proxy.lower(),
                "manifestHash": manifest_hash.lower(),
                "lastScannedBlock": last_scanned_block,
            },
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    temporary.replace(cursor_file)
