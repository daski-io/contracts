#!/usr/bin/env python3
"""Require exact equality of independently reproduced release evidence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

FIELDS = (
    "manifestHash",
    "sourceCommit",
    "forgeVersion",
    "castVersion",
    "foundryConfig",
    "foundryConfigHash",
    "sourceProvenance",
    "proxyRuntimeCodehash",
    "implementationRuntimeCodehashes",
    "finalizedRevisionHashes",
    "effectiveReleaseHash",
)


def compare(first: dict, second: dict) -> None:
    if first.get("schema") != "daski-release-reproduction/v1":
        raise ValueError("first reproduction schema mismatch")
    if second.get("schema") != "daski-release-reproduction/v1":
        raise ValueError("second reproduction schema mismatch")
    mismatches = [field for field in FIELDS if first.get(field) != second.get(field)]
    if mismatches:
        raise ValueError(f"release reproductions differ: {', '.join(mismatches)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    args = parser.parse_args()
    first = json.loads(args.first.read_text(encoding="utf-8"))
    second = json.loads(args.second.read_text(encoding="utf-8"))
    compare(first, second)
    print("Independent release reproductions match exactly.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"release reproduction comparison failed: {error}") from error
