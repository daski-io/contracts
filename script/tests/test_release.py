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


if __name__ == "__main__":
    unittest.main()
