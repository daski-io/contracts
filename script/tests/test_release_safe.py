import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_safe as safe_tools


class SafeExecutionVerificationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.safe = "0x" + "aa" * 20
        self.safe_hash = "0x" + "bb" * 32
        self.execution_hash = "0x" + "cc" * 32
        self.payload = bytes.fromhex("12345678")
        self.event_topic = safe_tools._keccak(safe_tools.EXECUTION_SUCCESS.encode(), "cast")
        self.exec_selector = safe_tools._selector(safe_tools.EXEC_TRANSACTION, "cast")
        self.input_data = "0x" + self._encode_exec_transaction(self.payload).hex()

    def _encode_exec_transaction(self, payload: bytes) -> bytes:
        target = bytes(12) + safe_tools._hex_bytes(safe_tools.MULTI_SEND_CALL_ONLY, 20)
        head = b"".join(
            (
                target,
                safe_tools._uint(0),
                safe_tools._uint(10 * 32),
                safe_tools._uint(1),
                safe_tools._uint(0),
                safe_tools._uint(0),
                safe_tools._uint(0),
                bytes(32),
                bytes(32),
                bytes(32),
            )
        )
        return self.exec_selector + head + safe_tools._uint(len(payload)) + payload + bytes((-len(payload)) % 32)

    def _command(self, command: list[str]) -> str:
        if command[1] == "receipt":
            return json.dumps(
                {
                    "status": "0x1",
                    "logs": [
                        {
                            "address": self.safe,
                            "topics": [self.event_topic],
                            "data": self.safe_hash + "00" * 32,
                        }
                    ],
                }
            )
        if command[1] == "tx":
            return json.dumps({"to": self.safe, "input": self.input_data})
        if command[1] == "keccak":
            return self.event_topic
        if command[1] == "sig":
            return "0x" + self.exec_selector.hex()
        raise AssertionError(f"unexpected command: {command}")

    def test_accepts_unindexed_safe_success_event_and_exact_payload(self) -> None:
        revision = {
            "safeTransactionHash": self.safe_hash,
            "executionTransactionHash": self.execution_hash,
        }
        with patch.object(safe_tools, "_command", side_effect=self._command):
            safe_tools._verify_execution(revision, self.safe, self.payload, "http://localhost", "cast")

    def test_rejects_executed_payload_that_differs_from_revision(self) -> None:
        revision = {
            "safeTransactionHash": self.safe_hash,
            "executionTransactionHash": self.execution_hash,
        }
        with patch.object(safe_tools, "_command", side_effect=self._command):
            with self.assertRaisesRegex(safe_tools.RevisionError, "payload mismatch"):
                safe_tools._verify_execution(revision, self.safe, b"different", "http://localhost", "cast")


if __name__ == "__main__":
    unittest.main()
