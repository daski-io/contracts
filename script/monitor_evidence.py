"""Archive external identity alerts under the effective release hash."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path


def write_alert(
    directory: Path,
    manifest_hash: str,
    effective_release_hash: str,
    actual: dict[str, str],
    differences: dict[str, dict[str, str]],
    transactions: list[dict[str, str]],
    alert: dict[str, str] | None,
) -> None:
    observed_at = datetime.now(timezone.utc).isoformat()
    (directory / "observation.json").write_text(
        json.dumps(
            {
                "manifestHash": manifest_hash,
                "effectiveReleaseHash": effective_release_hash,
                "observedAt": observed_at,
                "identity": actual,
                "mismatches": differences,
                "pauseTransactions": transactions,
                "alert": alert,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def archive_alert(
    evidence_root: Path,
    effective_release_hash: str,
    manifest_hash: str,
    actual: dict[str, str],
    differences: dict[str, dict[str, str]],
    transactions: list[dict[str, str]],
    alert: dict[str, str] | None = None,
) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    directory = evidence_root / effective_release_hash.removeprefix("0x") / f"{timestamp}-identity-alert"
    if directory.exists():
        raise FileExistsError(f"monitor evidence already exists: {directory}")
    directory.mkdir(parents=True)
    write_alert(
        directory,
        manifest_hash,
        effective_release_hash,
        actual,
        differences,
        transactions,
        alert,
    )
    return directory
