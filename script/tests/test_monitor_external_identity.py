import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import monitor_external_identity as monitor
import monitor_identity_chain as monitor_identity


class ExternalIdentityMonitorTest(unittest.TestCase):
    def test_storage_address_uses_low_twenty_bytes(self) -> None:
        word = "0x" + "00" * 12 + "ab" * 20
        self.assertEqual(monitor.storage_address(word), "0x" + "ab" * 20)

    def test_mismatch_comparison_normalizes_hex_case(self) -> None:
        expected = {"proxy": "0x" + "AA" * 20, "version": "2.0.0"}
        actual = {"proxy": "0x" + "aa" * 20, "version": "2.0.0"}
        self.assertEqual(monitor.mismatches(expected, actual), {})

    def test_observation_pins_every_rpc_read_to_one_block(self) -> None:
        proxy = "0x" + "11" * 20
        implementation = "0x" + "22" * 20
        identity = {
            "proxy": proxy,
            "proxyRuntimeCodehash": "0x" + "33" * 32,
            "implementation": implementation,
            "implementationRuntimeCodehash": "0x" + "44" * 32,
            "erc1967Admin": "0x" + "00" * 20,
            "upgradeAuthority": "0x" + "55" * 20,
            "version": "2.0.0",
        }
        calls: list[list[str]] = []

        def fake_command(arguments: list[str]) -> str:
            calls.append(arguments)
            self.assertIn("--block", arguments)
            self.assertEqual(arguments[arguments.index("--block") + 1], "123")
            if arguments[1] == "storage":
                address = (
                    implementation
                    if arguments[3] == monitor_identity.IMPLEMENTATION_SLOT
                    else "0x" + "00" * 20
                )
                return "0x" + "00" * 12 + address[2:]
            if arguments[1] == "codehash":
                return (
                    identity["proxyRuntimeCodehash"]
                    if arguments[2] == proxy
                    else identity["implementationRuntimeCodehash"]
                )
            if arguments[3] == "owner()(address)":
                return identity["upgradeAuthority"]
            if arguments[3] == "getVersion()(string)":
                return json.dumps(identity["version"])
            raise AssertionError(f"unexpected command: {arguments}")

        actual = monitor.observe(
            identity,
            "http://localhost",
            "cast",
            fake_command,
            123,
        )

        self.assertEqual(monitor.mismatches(identity, actual), {})
        self.assertEqual(actual["observedBlock"], "123")
        self.assertEqual(len(calls), 6)

    def test_event_scan_uses_contiguous_range_and_all_security_topics(self) -> None:
        proxy = "0x" + "11" * 20

        def fake_command(arguments: list[str]) -> str:
            event_filter = json.loads(arguments[3])
            self.assertEqual(event_filter["fromBlock"], "0xa")
            self.assertEqual(event_filter["toBlock"], "0xc")
            self.assertEqual(
                set(event_filter["topics"][0]),
                set(monitor_identity.EVENT_TOPICS),
            )
            return json.dumps(
                [
                    {
                        "topics": [next(iter(monitor_identity.EVENT_TOPICS))],
                        "blockNumber": "0xb",
                    }
                ]
            )

        events = monitor.scan_identity_events(
            proxy,
            10,
            12,
            "http://localhost",
            "cast",
            fake_command,
        )
        self.assertEqual(events[0]["event"], "Upgraded")

    def test_cursor_resumes_at_the_next_unscanned_block(self) -> None:
        proxy = "0x" + "11" * 20
        manifest_hash = "0x" + "22" * 32
        with tempfile.TemporaryDirectory() as directory:
            cursor = Path(directory) / "cursor.json"
            self.assertEqual(
                monitor.next_cursor_block(cursor, proxy, manifest_hash, 50),
                50,
            )
            monitor.write_cursor(cursor, proxy, manifest_hash, 55)
            self.assertEqual(
                monitor.next_cursor_block(cursor, proxy, manifest_hash, 99),
                56,
            )

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
