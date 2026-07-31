import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release as release_tool


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


class ReleaseCheckoutTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        git(self.repo, "init", "-b", "develop")
        git(self.repo, "config", "user.name", "Release Test")
        git(self.repo, "config", "user.email", "release@example.com")
        (self.repo / "foundry.lock").write_text("pinned\n", encoding="utf-8")
        git(self.repo, "add", "foundry.lock")
        git(self.repo, "commit", "-m", "initial")
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.manifest = {"build": {"sourceCommit": self.head}}
        self.inputs = self.repo / ".git" / "release-inputs"
        self.inputs.mkdir()
        self.manifest_path = self.inputs / "manifest.json"
        self.pinned_manifest = self.inputs / "pinned-manifest.json"
        self.manifest_bytes = b'{"release":"test"}\n'
        self.manifest_path.write_bytes(self.manifest_bytes)
        self.pinned_manifest.write_bytes(self.manifest_bytes)
        self.revision_path = self.inputs / "revision-evidence.json"
        self.revision_bytes = b'{"revision":"test"}\n'
        self.revision_path.write_bytes(self.revision_bytes)
        self.marker_path = self.inputs / "provenance.json"
        self.marker_bytes = b'{"schema":"daski-release-provenance/v2"}\n'
        self.marker_path.write_bytes(self.marker_bytes)
        self.revision = release_tool.revision_verifier.RevisionEvidence(
            effective_release_hash="0x" + "11" * 32,
            effective_facilitators=["0x" + "22" * 20],
            finalized=[],
            proposal=None,
            input_snapshots=[],
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_accepts_clean_release_ref_containing_head(self) -> None:
        checked = release_tool.check_checkout(self.repo, self.manifest, "develop")
        self.assertEqual(checked, self.head)

    def test_accepts_detached_head_contained_by_release_ref(self) -> None:
        git(self.repo, "checkout", "--detach", self.head)
        checked = release_tool.check_checkout(self.repo, self.manifest, "develop")
        self.assertEqual(checked, self.head)

    def test_rejects_untracked_file(self) -> None:
        (self.repo / "unexpected.txt").write_text("dirty\n", encoding="utf-8")
        with self.assertRaisesRegex(release_tool.ReleaseError, "checkout is dirty"):
            release_tool.check_checkout(self.repo, self.manifest, "develop")

    def test_rejects_wrong_source_commit(self) -> None:
        self.manifest["build"]["sourceCommit"] = "1" * 40
        with self.assertRaisesRegex(release_tool.ReleaseError, "HEAD does not equal"):
            release_tool.check_checkout(self.repo, self.manifest, "develop")

    def test_rejects_stale_build_output(self) -> None:
        (self.repo / "out").mkdir()
        with self.assertRaisesRegex(release_tool.ReleaseError, "stale build output"):
            release_tool.check_checkout(self.repo, self.manifest, "develop")

    def test_rejects_head_not_contained_by_release_ref(self) -> None:
        git(self.repo, "checkout", "-b", "other")
        (self.repo / "foundry.lock").write_text("changed\n", encoding="utf-8")
        git(self.repo, "add", "foundry.lock")
        git(self.repo, "commit", "-m", "other")
        self.manifest["build"]["sourceCommit"] = git(self.repo, "rev-parse", "HEAD")
        with self.assertRaisesRegex(release_tool.ReleaseError, "develop does not contain HEAD"):
            release_tool.check_checkout(self.repo, self.manifest, "develop")

    def test_rejects_ambient_build_overrides(self) -> None:
        for variable in (
            "FOUNDRY_REMAPPINGS",
            "DAPP_LIBRARIES",
            "SOLC_PATH",
            "RELEASE_E2E_LOCAL_FIXTURE",
        ):
            with self.subTest(variable=variable):
                with self.assertRaisesRegex(release_tool.ReleaseError, "unsafe build environment"):
                    release_tool.validate_ambient_environment({"PATH": "/bin", variable: "malicious"})

    def test_accepts_environment_without_build_overrides(self) -> None:
        release_tool.validate_ambient_environment({"PATH": "/bin", "RPC_URL": "https://example.invalid"})

    def test_accepts_unchanged_run_inputs(self) -> None:
        release_tool.verify_run_inputs(
            self.repo,
            self.manifest,
            self.manifest_path,
            self.manifest_bytes,
            self.pinned_manifest,
            self.revision,
            self.revision_path,
            self.revision_bytes,
            self.marker_path,
            self.marker_bytes,
            "develop",
            "cast",
        )

    def test_rejects_changed_manifest_before_forge(self) -> None:
        self.manifest_path.write_bytes(b"changed\n")
        with self.assertRaisesRegex(release_tool.ReleaseError, "manifest changed"):
            self.test_accepts_unchanged_run_inputs()

    def test_rejects_changed_revision_evidence_before_forge(self) -> None:
        self.revision_path.write_bytes(b"changed\n")
        with self.assertRaisesRegex(release_tool.ReleaseError, "revision evidence changed"):
            self.test_accepts_unchanged_run_inputs()

    def test_rejects_changed_marker_before_forge(self) -> None:
        self.marker_path.write_bytes(b"changed\n")
        with self.assertRaisesRegex(release_tool.ReleaseError, "marker changed"):
            self.test_accepts_unchanged_run_inputs()

    def test_rejects_changed_pinned_manifest_before_forge(self) -> None:
        self.pinned_manifest.write_bytes(b"changed\n")
        with self.assertRaisesRegex(release_tool.ReleaseError, "pinned release manifest changed"):
            self.test_accepts_unchanged_run_inputs()


if __name__ == "__main__":
    unittest.main()
