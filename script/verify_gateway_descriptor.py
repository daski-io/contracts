#!/usr/bin/env python3
"""Verify the public gateway descriptor against the reviewed release manifest."""

from __future__ import annotations

import argparse
import json
import urllib.request
from pathlib import Path
from typing import Any

CONTRACT_KEYS = (
    "agentIndex",
    "validationRegistry",
    "providerRegistry",
    "serviceRegistry",
    "paymentRouter",
    "reputationStorage",
    "x402Adapter",
    "permitAdapter",
    "approvalAdapter",
)
NETWORKS = {8453: "base", 84532: "base-sepolia"}


def normalize(value: Any) -> Any:
    if isinstance(value, str) and value.startswith("0x"):
        return value.lower()
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def expected_descriptor(manifest: dict[str, Any]) -> dict[str, Any]:
    proxies = manifest["contracts"]["proxies"]
    if len(proxies) != len(CONTRACT_KEYS):
        raise ValueError("manifest must contain nine proxies")
    external = manifest["external"]
    return {
        "chainId": manifest["chainId"],
        "network": NETWORKS[manifest["chainId"]],
        "contracts": {
            "identityRegistry": external["identityRegistry"]["proxy"],
            **dict(zip(CONTRACT_KEYS, proxies)),
            "sanctionsOracle": external["sanctionsOracle"],
            "usdc": external["usdc"]["address"],
            "eas": external["eas"],
        },
        "schemas": {
            "easConfirmation": manifest["schemas"]["confirmation"]["uid"],
            "easOutcome": manifest["schemas"]["outcome"]["uid"],
        },
        "usdcDomain": external["usdc"],
    }


def verify(manifest: dict[str, Any], descriptor: dict[str, Any]) -> None:
    expected = expected_descriptor(manifest)
    actual = {
        "chainId": descriptor.get("chainId"),
        "network": descriptor.get("network"),
        "contracts": {
            key: descriptor.get("contracts", {}).get(key)
            for key in expected["contracts"]
        },
        "schemas": descriptor.get("schemas"),
        "usdcDomain": descriptor.get("usdcDomain"),
    }
    if normalize(actual) != normalize(expected):
        raise ValueError("gateway descriptor does not match the reviewed release manifest")


def load_url(gateway_url: str) -> dict[str, Any]:
    url = gateway_url.rstrip("/") + "/.well-known/daski-chain.json"
    with urllib.request.urlopen(url, timeout=15) as response:
        if response.status != 200:
            raise ValueError(f"gateway descriptor returned HTTP {response.status}")
        return json.loads(response.read())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--gateway-url")
    source.add_argument("--descriptor-file", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if args.descriptor_file:
        raw_descriptor = args.descriptor_file.read_bytes()
        descriptor = json.loads(raw_descriptor)
    else:
        descriptor = load_url(args.gateway_url)
    verify(manifest, descriptor)
    print("Gateway descriptor matches the reviewed release manifest.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        raise SystemExit(f"gateway descriptor verification failed: {error}") from error
