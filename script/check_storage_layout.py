#!/usr/bin/env python3
"""Compare normalized upgradeable storage layouts with the audited baseline."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any

CONTRACTS = (
    "AgentIndex",
    "DaskiValidationRegistry",
    "ProviderRegistry",
    "ServiceRegistry",
    "PaymentRouter",
    "ReputationStorage",
    "X402Adapter",
    "PermitAdapter",
    "ApprovalAdapter",
)
FIRST_DERIVED_STORAGE = {
    "AgentIndex": ("100", "identity"),
    "DaskiValidationRegistry": ("100", "identityRegistry"),
    "ProviderRegistry": ("100", "_providers"),
    "ServiceRegistry": ("100", "identity"),
    "PaymentRouter": ("100", "treasury"),
    "ReputationStorage": ("100", "_records"),
    "X402Adapter": ("100", "router"),
    "PermitAdapter": ("100", "router"),
    "ApprovalAdapter": ("100", "router"),
}


class LayoutError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise LayoutError(message)


def _type_shape(identifier: str, types: dict[str, Any]) -> dict[str, Any]:
    value = types[identifier]
    shape: dict[str, Any] = {
        "encoding": value["encoding"],
        "label": value["label"],
        "numberOfBytes": value["numberOfBytes"],
    }
    for field in ("base", "key", "value"):
        nested = value.get(field)
        if nested is not None:
            shape[field] = _type_shape(nested, types)
    if "members" in value:
        shape["members"] = [
            {
                "label": member["label"],
                "offset": member["offset"],
                "slot": member["slot"],
                "type": _type_shape(member["type"], types),
            }
            for member in value["members"]
        ]
    return shape


def normalize(contract: str, layout: dict[str, Any]) -> dict[str, Any]:
    types = layout["types"]
    storage = [
        {
            "order": index,
            "label": item["label"],
            "offset": item["offset"],
            "slot": item["slot"],
            "type": _type_shape(item["type"], types),
        }
        for index, item in enumerate(layout["storage"])
    ]
    _require_guard_layout(contract, storage)
    return {"contract": contract, "storage": storage}


def _require_guard_layout(contract: str, storage: list[dict[str, Any]]) -> None:
    guardian = [item for item in storage if item["label"] == "pauseGuardian"]
    paused = [item for item in storage if item["label"] == "externalDependencyPaused"]
    gap = [
        item
        for item in storage
        if item["label"] == "__gap" and item["slot"] == "53"
    ]
    require(
        len(guardian) == 1 and guardian[0]["slot"] == "52" and guardian[0]["offset"] == 0,
        f"{contract}: pauseGuardian must begin former base-gap slot 52",
    )
    require(
        len(paused) == 1 and paused[0]["slot"] == "52" and paused[0]["offset"] == 20,
        f"{contract}: externalDependencyPaused must share slot 52 at offset 20",
    )
    require(
        len(gap) == 1 and gap[0]["type"]["label"] == "uint256[47]",
        f"{contract}: remaining base gap must begin at slot 53",
    )
    expected_slot, expected_label = FIRST_DERIVED_STORAGE[contract]
    derived = next((item for item in storage if int(item["slot"]) >= 100), None)
    require(
        derived is not None
        and derived["slot"] == expected_slot
        and derived["label"] == expected_label,
        f"{contract}: first derived storage changed",
    )


def inspect(repo: Path, forge: str) -> dict[str, Any]:
    normalized = []
    for contract in CONTRACTS:
        result = subprocess.run(
            [forge, "inspect", contract, "storage-layout", "--json"],
            cwd=repo,
            check=False,
            capture_output=True,
            text=True,
        )
        require(result.returncode == 0, result.stderr.strip() or f"forge inspect failed: {contract}")
        normalized.append(normalize(contract, json.loads(result.stdout)))
    return {"schema": "daski-storage-layout/v1", "contracts": normalized}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--forge", default="forge")
    parser.add_argument(
        "--baseline",
        type=Path,
        default=Path("storage-layout/baseline.json"),
    )
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="review-only operation; CI must never use this flag",
    )
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    baseline = args.baseline if args.baseline.is_absolute() else repo / args.baseline
    actual = inspect(repo, args.forge)
    rendered = json.dumps(actual, indent=2, sort_keys=True) + "\n"
    if args.write_baseline:
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_text(rendered, encoding="utf-8")
        print(f"Wrote reviewed storage layout baseline: {baseline}")
        return
    require(baseline.is_file(), f"storage layout baseline is missing: {baseline}")
    expected = json.loads(baseline.read_text(encoding="utf-8"))
    require(actual == expected, "storage layout differs from the reviewed baseline")
    print("Storage layout matches the reviewed baseline.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError, LayoutError) as error:
        raise SystemExit(f"storage layout check failed: {error}") from error
