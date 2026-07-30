#!/usr/bin/env python3
"""Fail closed unless an RPC serves the reviewed pinned USDC fork state."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import urllib.request


class PreflightError(RuntimeError):
    pass


def rpc(url: str, method: str, params: list[object]) -> object:
    request = urllib.request.Request(
        url,
        data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "daski-release-preflight/1",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    if "error" in payload:
        raise PreflightError(f"{method} failed: {payload['error']}")
    if payload.get("result") is None:
        raise PreflightError(f"{method} returned no result")
    return payload["result"]


def decode_string(value: str) -> str:
    raw = bytes.fromhex(value.removeprefix("0x"))
    if len(raw) < 64:
        raise PreflightError("invalid ABI string response")
    offset = int.from_bytes(raw[:32], "big")
    length = int.from_bytes(raw[offset : offset + 32], "big")
    return raw[offset + 32 : offset + 32 + length].decode()


def eth_call(url: str, token: str, data: str, block: str) -> str:
    result = rpc(url, "eth_call", [{"to": token, "data": data}, block])
    if not isinstance(result, str) or not result.startswith("0x"):
        raise PreflightError("invalid eth_call result")
    return result.lower()


def keccak(data: bytes, cast: str) -> str:
    result = subprocess.run(
        [cast, "keccak", "0x" + data.hex()],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip().lower()
    if result.returncode != 0 or re.fullmatch(r"0x[0-9a-f]{64}", value) is None:
        raise PreflightError(result.stderr.strip() or "cast keccak failed")
    return value


def compute_domain(token: str, name: str, version: str, chain_id: int, cast: str) -> str:
    type_hash = keccak(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
        cast,
    )
    encoded = (
        bytes.fromhex(type_hash[2:])
        + bytes.fromhex(keccak(name.encode(), cast)[2:])
        + bytes.fromhex(keccak(version.encode(), cast)[2:])
        + chain_id.to_bytes(32, "big")
        + int(token, 16).to_bytes(32, "big")
    )
    return keccak(encoded, cast)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--chain-id", required=True, type=int)
    parser.add_argument("--block", required=True, type=int)
    parser.add_argument("--block-hash", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--domain-separator", required=True)
    parser.add_argument("--cast", default="cast")
    args = parser.parse_args()
    cast = shutil.which(args.cast)
    if cast is None:
        raise PreflightError("cast must be on PATH")

    chain_id = int(str(rpc(args.rpc_url, "eth_chainId", [])), 16)
    if chain_id != args.chain_id:
        raise PreflightError(f"wrong chain ID: {chain_id}")

    block_tag = hex(args.block)
    block = rpc(args.rpc_url, "eth_getBlockByNumber", [block_tag, False])
    if not isinstance(block, dict):
        raise PreflightError("invalid pinned block response")
    if block.get("number") != block_tag:
        raise PreflightError("RPC substituted a different fork block")
    if str(block.get("hash", "")).lower() != args.block_hash.lower():
        raise PreflightError("pinned block hash mismatch")

    code = rpc(args.rpc_url, "eth_getCode", [args.token, block_tag])
    if not isinstance(code, str) or code in ("", "0x"):
        raise PreflightError("USDC code unavailable at pinned block")

    decimals = int(eth_call(args.rpc_url, args.token, "0x313ce567", block_tag), 16)
    name = decode_string(eth_call(args.rpc_url, args.token, "0x06fdde03", block_tag))
    version = decode_string(eth_call(args.rpc_url, args.token, "0x54fd4d50", block_tag))
    domain = eth_call(args.rpc_url, args.token, "0x3644e515", block_tag)
    runtime_codehash = keccak(bytes.fromhex(code.removeprefix("0x")), cast)
    computed_domain = compute_domain(args.token, name, version, chain_id, cast)
    if decimals != 6:
        raise PreflightError(f"wrong USDC decimals: {decimals}")
    if name != args.name:
        raise PreflightError(f"wrong USDC name: {name}")
    if version != args.version:
        raise PreflightError(f"wrong USDC version: {version}")
    if domain != args.domain_separator.lower():
        raise PreflightError("wrong USDC domain separator")
    if computed_domain != domain:
        raise PreflightError("computed USDC domain separator mismatch")

    print(
        json.dumps(
            {
                "chainId": chain_id,
                "blockNumber": args.block,
                "blockHash": block["hash"],
                "token": args.token,
                "runtimeCodehash": runtime_codehash,
                "decimals": decimals,
                "name": name,
                "version": version,
                "domainSeparator": domain,
                "computedDomainSeparator": computed_domain,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, PreflightError) as error:
        raise SystemExit(f"fork RPC preflight failed: {error}") from error
