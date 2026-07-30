import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import monitor_external_identity as monitor


class ExternalIdentityMonitorTest(unittest.TestCase):
    def test_storage_address_uses_low_twenty_bytes(self) -> None:
        word = "0x" + "00" * 12 + "ab" * 20
        self.assertEqual(monitor.storage_address(word), "0x" + "ab" * 20)

    def test_mismatch_comparison_normalizes_hex_case(self) -> None:
        expected = {"proxy": "0x" + "AA" * 20, "version": "2.0.0"}
        actual = {"proxy": "0x" + "aa" * 20, "version": "2.0.0"}
        self.assertEqual(monitor.mismatches(expected, actual), {})

    def test_pause_orders_payment_router_first_and_confirms_every_proxy(self) -> None:
        proxies = ["0x" + f"{index + 1:040x}" for index in range(9)]
        transactions: list[dict[str, str]] = []

        def fake_command(arguments: list[str]) -> str:
            if arguments[1] == "sig":
                return "0x12345678"
            if arguments[1] == "call":
                return "true"
            raise AssertionError(f"unexpected command: {arguments}")

        completed = subprocess.CompletedProcess([], 0, stdout="0xtxhash\n", stderr="")
        with (
            patch.object(monitor, "command", side_effect=fake_command),
            patch.object(monitor.subprocess, "run", return_value=completed),
        ):
            monitor.pause_stack(
                proxies,
                "http://localhost",
                "0x" + "11" * 32,
                Path("/guardian"),
                [],
                "cast",
                transactions,
            )

        self.assertEqual([entry["target"] for entry in transactions], [proxies[i] for i in monitor.PAUSE_ORDER])
        self.assertEqual(transactions[0]["target"], proxies[monitor.PAYMENT_ROUTER_INDEX])
        self.assertTrue(all(entry["confirmed"] == "true" for entry in transactions))

    def test_alert_receives_bound_evidence_identity(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="alert-id\n", stderr="")
        with patch.object(monitor.subprocess, "run", return_value=completed) as run:
            evidence = monitor.notify(
                Path("/alert"),
                ["--destination", "security"],
                Path("/evidence/run"),
                "0x" + "11" * 32,
                "0x" + "22" * 32,
            )

        self.assertEqual(evidence["submitted"], "true")
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[:3], ["/alert", "--destination", "security"])
        self.assertIn("/evidence/run", arguments)
        self.assertIn("0x" + "11" * 32, arguments)
        self.assertIn("0x" + "22" * 32, arguments)


if __name__ == "__main__":
    unittest.main()
