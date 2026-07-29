"""Safe payload construction and execution receipt verification."""

from __future__ import annotations

import json
import re
import subprocess
from typing import Any

MULTI_SEND_CALL_ONLY = "0x9641d764fc13c8b624c04430c7356c1c7c8102e2"
EXECUTION_SUCCESS = "ExecutionSuccess(bytes32,uint256)"
SET_FACILITATOR = "setFacilitatorAuthorization(address,bool)"
MULTI_SEND = "multiSend(bytes)"
EXEC_TRANSACTION = "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"


class RevisionError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RevisionError(message)


def _command(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or f"{command[0]} failed")
    return result.stdout.strip()


def _hex_bytes(value: str, width: int) -> bytes:
    require(
        isinstance(value, str) and re.fullmatch(rf"0x[0-9a-fA-F]{{{width * 2}}}", value) is not None,
        "invalid hex value",
    )
    return bytes.fromhex(value[2:])


def _uint(value: int) -> bytes:
    return value.to_bytes(32, "big")


def _keccak(data: bytes, cast: str) -> str:
    return _command([cast, "keccak", "0x" + data.hex()]).lower()


def _selector(signature: str, cast: str) -> bytes:
    return _hex_bytes(_command([cast, "sig", signature]), 4)


def _facilitator_call(facilitator: str, authorized: bool, cast: str) -> bytes:
    return (
        _selector(SET_FACILITATOR, cast)
        + bytes(12)
        + _hex_bytes(facilitator, 20)
        + _uint(1 if authorized else 0)
    )


def _multi_send_payload(current: list[str], target: list[str], adapter: str, cast: str) -> bytes:
    current_lower = [value.lower() for value in current]
    target_lower = [value.lower() for value in target]
    calls: list[bytes] = []
    for facilitator in current:
        if facilitator.lower() not in target_lower:
            calls.append(_facilitator_call(facilitator, False, cast))
    for facilitator in target:
        if facilitator.lower() not in current_lower:
            calls.append(_facilitator_call(facilitator, True, cast))
    require(calls, "facilitator revision makes no change")

    packed = b""
    for call in calls:
        packed += b"\x00" + _hex_bytes(adapter, 20) + bytes(32) + _uint(len(call)) + call
    padding = bytes((-len(packed)) % 32)
    return _selector(MULTI_SEND, cast) + _uint(32) + _uint(len(packed)) + packed + padding


def _decode_exec_transaction(input_data: str, cast: str) -> tuple[str, int, bytes]:
    require(isinstance(input_data, str) and input_data.startswith("0x"), "invalid Safe transaction input")
    raw = _hex_bytes(input_data, (len(input_data) - 2) // 2)
    require(raw[:4] == _selector(EXEC_TRANSACTION, cast), "execution is not Safe execTransaction")
    head = raw[4 : 4 + 10 * 32]
    require(len(head) == 10 * 32, "truncated Safe transaction")
    target = "0x" + head[12:32].hex()
    operation = int.from_bytes(head[3 * 32 : 4 * 32], "big")
    data_offset = int.from_bytes(head[2 * 32 : 3 * 32], "big")
    data_start = 4 + data_offset
    data_length = int.from_bytes(raw[data_start : data_start + 32], "big")
    data = raw[data_start + 32 : data_start + 32 + data_length]
    require(len(data) == data_length, "truncated Safe payload")
    return target, operation, data


def _verify_execution(
    revision: dict[str, Any],
    safe: str,
    expected_payload: bytes,
    rpc_url: str,
    cast: str,
) -> None:
    execution_hash = revision["executionTransactionHash"]
    receipt = json.loads(_command([cast, "receipt", execution_hash, "--rpc-url", rpc_url, "--json"]))
    status = receipt.get("status")
    require(status in ("0x1", 1, "1"), "revision execution failed")
    event_topic = _keccak(EXECUTION_SUCCESS.encode(), cast)
    safe_hash = revision["safeTransactionHash"].lower()
    found = False
    for log in receipt.get("logs", []):
        topics = [value.lower() for value in log.get("topics", [])]
        log_address = log.get("address")
        if (
            not isinstance(log_address, str)
            or log_address.lower() != safe.lower()
            or not topics
            or topics[0] != event_topic
        ):
            continue
        if len(topics) > 1:
            found = topics[1] == safe_hash
        else:
            data = log.get("data", "")
            found = isinstance(data, str) and data[:66].lower() == safe_hash
        if found:
            break
    require(found, "missing Safe ExecutionSuccess event")

    transaction = json.loads(_command([cast, "tx", execution_hash, "--rpc-url", rpc_url, "--json"]))
    transaction_target = transaction.get("to")
    require(
        isinstance(transaction_target, str) and transaction_target.lower() == safe.lower(),
        "revision transaction did not call Safe",
    )
    input_data = transaction.get("input") or transaction.get("data")
    require(isinstance(input_data, str), "revision transaction input missing")
    target, operation, payload = _decode_exec_transaction(input_data, cast)
    require(target.lower() == MULTI_SEND_CALL_ONLY, "wrong Safe MultiSend target")
    require(operation == 1, "Safe revision must delegatecall MultiSendCallOnly")
    require(payload == expected_payload, "executed facilitator payload mismatch")


def _expected_safe_hash(safe: str, payload: bytes, rpc_url: str, cast: str) -> tuple[int, str]:
    nonce = int(_command([cast, "call", safe, "nonce()(uint256)", "--rpc-url", rpc_url]), 0)
    zero = "0x0000000000000000000000000000000000000000"
    safe_hash = _command(
        [
            cast,
            "call",
            safe,
            "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
            MULTI_SEND_CALL_ONLY,
            "0",
            "0x" + payload.hex(),
            "1",
            "0",
            "0",
            "0",
            zero,
            zero,
            str(nonce),
            "--rpc-url",
            rpc_url,
        ]
    ).lower()
    return nonce, safe_hash
