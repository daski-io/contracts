#!/usr/bin/env python3
"""Capture the exact standard-json input before proxying to pinned solc."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def compiler_identity(compiler: str) -> dict[str, str]:
    result = subprocess.run(
        [compiler, "--version"],
        check=True,
        capture_output=True,
        text=True,
    )
    match = re.search(r"Version: (0\.8\.24\+commit\.e11b9ed9)", result.stdout)
    if match is None:
        raise RuntimeError("unrecognized solc version output")
    return {"version": match.group(1)}


def capture(directory: Path, compiler: str, raw_input: bytes) -> None:
    parsed = json.loads(raw_input)
    digest = hashlib.sha256(raw_input).hexdigest()
    payload = {
        "schema": "daski-solc-input/v1",
        "compiler": compiler_identity(compiler),
        "inputSha256": digest,
        "input": parsed,
    }
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{digest}.json"
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if path.read_text(encoding="utf-8") != rendered:
            raise RuntimeError("conflicting captured compiler input")
        return
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(rendered)


def main() -> int:
    compiler = os.environ["DASKI_REAL_COMPILER"]
    capture_dir = Path(os.environ["DASKI_COMPILER_INPUT_DIR"])
    if "--standard-json" not in sys.argv[1:]:
        return subprocess.run([compiler, *sys.argv[1:]], check=False).returncode

    raw_input = sys.stdin.buffer.read()
    capture(capture_dir, compiler, raw_input)
    result = subprocess.run(
        [compiler, *sys.argv[1:]],
        input=raw_input,
        check=False,
        capture_output=True,
    )
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, RuntimeError) as error:
        raise SystemExit(f"solc capture failed: {error}") from error
