"""Facilitator revision proposal and finalized Safe execution verification."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from release_safe import (
    MULTI_SEND_CALL_ONLY,
    RevisionError,
    _expected_safe_hash,
    _hex_bytes,
    _keccak,
    _multi_send_payload,
    _uint,
    _verify_execution,
    require,
)

DOMAIN = b"DASKI_RELEASE_EVIDENCE_V1"
INTENT_DOMAIN = b"DASKI_FACILITATOR_REVISION_V1"
REVISION_FIELDS = {
    "revision",
    "kind",
    "baseManifestHash",
    "previousManifestHash",
    "safeTransactionHash",
    "executionTransactionHash",
    "authorizedFacilitators",
}


def _intent_hash(revision: dict[str, Any], chain_id: int, cast: str) -> str:
    kind_hash = _hex_bytes(_keccak(revision["kind"].encode(), cast), 32)
    encoded = (
        INTENT_DOMAIN
        + _uint(chain_id)
        + _uint(revision["revision"])
        + kind_hash
        + _hex_bytes(revision["baseManifestHash"], 32)
        + _hex_bytes(revision["previousManifestHash"], 32)
    )
    for facilitator in revision["authorizedFacilitators"]:
        encoded += _hex_bytes(facilitator, 20)
    return _keccak(encoded, cast)


def _effective_hash(base_hash: str, revision_hashes: list[str], chain_id: int, cast: str) -> str:
    encoded = DOMAIN + _uint(chain_id) + _hex_bytes(base_hash, 32)
    for revision_hash in revision_hashes:
        encoded += _hex_bytes(revision_hash, 32)
    return _keccak(encoded, cast)


@dataclass
class RevisionEvidence:
    effective_release_hash: str
    effective_facilitators: list[str]
    finalized: list[dict[str, Any]]
    proposal: dict[str, Any] | None
    input_snapshots: list[tuple[Path, str]]


def verify_inputs_unchanged(evidence: RevisionEvidence, cast: str) -> None:
    for path, expected_hash in evidence.input_snapshots:
        require(_keccak(path.read_bytes(), cast) == expected_hash, f"revision changed during run: {path}")


def process(
    paths: list[Path],
    pinned_dir: Path,
    manifest_bytes: bytes,
    manifest: dict[str, Any],
    chain_id: int,
    rpc_url: str,
    cast: str,
    proposal_mode: bool,
) -> RevisionEvidence:
    base_hash = _keccak(manifest_bytes, cast)
    current = list(manifest["x402"]["authorizedFacilitators"])
    previous_hash = base_hash
    revision_hashes: list[str] = []
    finalized: list[dict[str, Any]] = []
    proposal: dict[str, Any] | None = None
    input_snapshots: list[tuple[Path, str]] = []
    pinned_dir.mkdir()

    for index, source_path in enumerate(paths):
        raw = source_path.read_bytes()
        revision = json.loads(raw)
        input_snapshots.append((source_path, _keccak(raw, cast)))
        require(isinstance(revision, dict), "revision must be a JSON object")
        require(set(revision) == REVISION_FIELDS, "revision schema mismatch")
        require(revision.get("revision") == index + 1, "non-monotonic manifest revision")
        require(revision.get("baseManifestHash", "").lower() == base_hash, "revision base manifest mismatch")
        require(
            revision.get("previousManifestHash", "").lower() == previous_hash,
            "broken manifest revision link",
        )
        target = revision.get("authorizedFacilitators", [])
        require(isinstance(target, list) and target, "invalid facilitator set")
        for facilitator in target:
            require(
                isinstance(facilitator, str)
                and re.fullmatch(r"0x[0-9a-fA-F]{40}", facilitator) is not None
                and int(facilitator, 16) != 0,
                "invalid facilitator",
            )
        require(len({value.lower() for value in target}) == len(target), "invalid facilitator set")
        kind = revision.get("kind")
        require(kind in ("planned", "emergency-remove-only"), "unsupported manifest revision kind")
        if kind == "emergency-remove-only":
            require(
                all(value.lower() in {item.lower() for item in current} for value in target),
                "emergency revision added facilitator",
            )

        intent_hash = _intent_hash(revision, chain_id, cast)
        execution_hash = revision.get("executionTransactionHash", "")
        safe_hash = revision.get("safeTransactionHash", "")
        _hex_bytes(execution_hash, 32)
        _hex_bytes(safe_hash, 32)
        is_last_proposal = proposal_mode and index == len(paths) - 1
        if is_last_proposal:
            require(int(execution_hash, 16) == 0, "proposal already has execution transaction")
            payload = _multi_send_payload(
                current, target, manifest["contracts"]["proxies"][6], cast
            )
            safe_nonce, expected_safe_hash = _expected_safe_hash(
                manifest["governance"]["safe"], payload, rpc_url, cast
            )
            declared_safe_hash = revision.get("safeTransactionHash", "")
            if int(declared_safe_hash, 16) != 0:
                require(declared_safe_hash.lower() == expected_safe_hash, "Safe transaction hash mismatch")
            proposal = {
                "revisionIntentHash": intent_hash,
                "safeNonce": safe_nonce,
                "expectedSafeTransactionHash": expected_safe_hash,
                "safe": manifest["governance"]["safe"],
                "to": MULTI_SEND_CALL_ONLY,
                "operation": 1,
                "data": "0x" + payload.hex(),
                "authorizedFacilitators": target,
            }
            (pinned_dir / f"{index + 1:04d}-proposal.json").write_bytes(raw)
            break

        require(int(safe_hash, 16) != 0 and int(execution_hash, 16) != 0, "revision is not finalized")
        payload = _multi_send_payload(current, target, manifest["contracts"]["proxies"][6], cast)
        _verify_execution(revision, manifest["governance"]["safe"], payload, rpc_url, cast)
        revision_hash = _keccak(raw, cast)
        destination = pinned_dir / f"{index + 1:04d}-{revision_hash[2:]}.json"
        destination.write_bytes(raw)
        finalized.append(
            {
                "revision": index + 1,
                "revisionIntentHash": intent_hash,
                "revisionHash": revision_hash,
                "safeTransactionHash": safe_hash,
                "executionTransactionHash": execution_hash,
                "file": destination.name,
            }
        )
        revision_hashes.append(revision_hash)
        previous_hash = revision_hash
        current = target

    return RevisionEvidence(
        effective_release_hash=_effective_hash(base_hash, revision_hashes, chain_id, cast),
        effective_facilitators=current,
        finalized=finalized,
        proposal=proposal,
        input_snapshots=input_snapshots,
    )
