import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_revision as revisions


class RevisionLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest = {
            "chainId": 8453,
            "contracts": {"proxies": ["0x" + f"{index:040x}" for index in range(1, 10)]},
            "governance": {"safe": "0x" + "aa" * 20},
            "x402": {"authorizedFacilitators": ["0x" + "11" * 20, "0x" + "22" * 20]},
        }
        self.manifest_bytes = json.dumps(self.manifest, separators=(",", ":")).encode()
        self.base_hash = revisions._keccak(self.manifest_bytes, "cast")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write(self, data: dict) -> Path:
        path = self.root / "revision.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def _revision(self, kind: str, facilitators: list[str]) -> dict:
        return {
            "revision": 1,
            "kind": kind,
            "baseManifestHash": self.base_hash,
            "previousManifestHash": self.base_hash,
            "safeTransactionHash": "0x" + "00" * 32,
            "executionTransactionHash": "0x" + "00" * 32,
            "authorizedFacilitators": facilitators,
        }

    @patch.object(revisions, "_expected_safe_hash", return_value=(7, "0x" + "33" * 32))
    def test_proposal_keeps_intent_provisional(self, _safe_hash) -> None:
        path = self._write(self._revision("planned", ["0x" + "22" * 20]))
        evidence = revisions.process(
            [path],
            self.root / "pinned",
            self.manifest_bytes,
            self.manifest,
            8453,
            "http://localhost",
            "cast",
            True,
        )
        self.assertIsNotNone(evidence.proposal)
        self.assertEqual(evidence.finalized, [])
        self.assertEqual(evidence.proposal["safeNonce"], 7)
        self.assertEqual(evidence.effective_facilitators, self.manifest["x402"]["authorizedFacilitators"])
        self.assertEqual(evidence.proposal["authorizedFacilitators"], ["0x" + "22" * 20])

    def test_emergency_revision_cannot_add_facilitator(self) -> None:
        path = self._write(
            self._revision(
                "emergency-remove-only",
                ["0x" + "11" * 20, "0x" + "33" * 20],
            )
        )
        with self.assertRaisesRegex(revisions.RevisionError, "emergency revision added"):
            revisions.process(
                [path],
                self.root / "pinned",
                self.manifest_bytes,
                self.manifest,
                8453,
                "http://localhost",
                "cast",
                True,
            )

    def test_normal_modes_reject_unfinalized_revision(self) -> None:
        path = self._write(self._revision("planned", ["0x" + "11" * 20]))
        with self.assertRaisesRegex(revisions.RevisionError, "not finalized"):
            revisions.process(
                [path],
                self.root / "pinned",
                self.manifest_bytes,
                self.manifest,
                8453,
                "http://localhost",
                "cast",
                False,
            )

    def test_rejects_legacy_approval_field(self) -> None:
        revision = self._revision("planned", ["0x" + "11" * 20])
        revision["approved"] = True
        path = self._write(revision)
        with self.assertRaisesRegex(revisions.RevisionError, "schema mismatch"):
            revisions.process(
                [path],
                self.root / "pinned",
                self.manifest_bytes,
                self.manifest,
                8453,
                "http://localhost",
                "cast",
                True,
            )

    @patch.object(revisions, "_expected_safe_hash", return_value=(7, "0x" + "33" * 32))
    def test_detects_revision_mutation_after_pinning(self, _safe_hash) -> None:
        path = self._write(self._revision("planned", ["0x" + "22" * 20]))
        evidence = revisions.process(
            [path],
            self.root / "pinned",
            self.manifest_bytes,
            self.manifest,
            8453,
            "http://localhost",
            "cast",
            True,
        )
        path.write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(revisions.RevisionError, "changed during run"):
            revisions.verify_inputs_unchanged(evidence, "cast")

    def test_effective_hash_commits_to_ordered_revision_list(self) -> None:
        hashes = ["0x" + "33" * 32, "0x" + "44" * 32]
        encoded = (
            revisions.DOMAIN
            + revisions._uint(8453)
            + revisions._hex_bytes(self.base_hash, 32)
            + b"".join(revisions._hex_bytes(value, 32) for value in hashes)
        )
        self.assertEqual(
            revisions._effective_hash(self.base_hash, hashes, 8453, "cast"),
            revisions._keccak(encoded, "cast"),
        )


if __name__ == "__main__":
    unittest.main()
