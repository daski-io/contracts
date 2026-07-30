import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_release_build as verifier

FORGE_OUTPUT = """forge Version: 1.5.1-stable
Commit SHA: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
Build Timestamp: test
Build Profile: test"""
CAST_OUTPUT = """cast Version: 1.5.1-stable
Commit SHA: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
Build Timestamp: test
Build Profile: test"""


def fake_hash(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def fake_keccak(data: bytes, _cast: str) -> str:
    return fake_hash(data)


def fake_command(command: list[str]) -> str:
    if command[-1] == "--version":
        return CAST_OUTPUT if command[0] == "cast" else FORGE_OUTPUT
    if len(command) == 3 and command[1] == "keccak":
        return fake_hash(bytes.fromhex(command[2].removeprefix("0x")))
    raise AssertionError(f"unexpected command: {command}")


def metadata() -> dict:
    return {
        "compiler": {"version": verifier.SOLC_VERSION},
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "viaIR": True,
            "evmVersion": verifier.EVM_VERSION,
        },
    }


def implementation_artifact() -> dict:
    return {
        "metadata": metadata(),
        "rawMetadata": json.dumps({"sources": {verifier.UUPS_SOURCE: {}}}),
        "ir": (
            'setimmutable(_1, "1", mload(128))\n'
            '/// @src 1:1:1  "__self"\n'
            'let value := loadimmutable("1")\n'
        ),
        "deployedBytecode": {
            "object": "00" * 64,
            "linkReferences": {},
            "immutableReferences": {
                "1": [{"start": 0, "length": 32}, {"start": 32, "length": 32}]
            },
        },
    }


def proxy_artifact() -> dict:
    return {
        "metadata": metadata(),
        "rawMetadata": "{}",
        "ir": "",
        "deployedBytecode": {
            "object": "6000",
            "linkReferences": {},
            "immutableReferences": {},
        },
    }


class ReleaseBuildVerifierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / "out"
        self.implementations = [f"0x{index:040x}" for index in range(1, 10)]
        implementation_hashes = []
        for contract, implementation in zip(verifier.CONTRACTS, self.implementations):
            directory = self.output / f"{contract}.sol"
            directory.mkdir(parents=True)
            artifact = implementation_artifact()
            (directory / f"{contract}.json").write_text(json.dumps(artifact), encoding="utf-8")
            encoded = int(implementation, 16).to_bytes(32, "big")
            implementation_hashes.append(fake_hash(encoded + encoded))

        proxy_directory = self.output / "ERC1967Proxy.sol"
        proxy_directory.mkdir(parents=True)
        (proxy_directory / "ERC1967Proxy.json").write_text(json.dumps(proxy_artifact()), encoding="utf-8")
        proxy_hash = fake_hash(bytes.fromhex("6000"))
        self.manifest = {
            "chainId": 84532,
            "build": {
                "sourceCommit": "1" * 40,
                "sourceClosureHash": "0x" + "11" * 32,
                "compilerInputHash": "0x" + "22" * 32,
                "foundryConfigHash": "0x" + "33" * 32,
                "solcVersion": verifier.SOLC_VERSION,
                "optimizer": True,
                "optimizerRuns": 200,
                "viaIr": True,
                "evmVersion": verifier.EVM_VERSION,
                "foundryVersion": verifier.FOUNDRY_VERSION,
                "foundryCommit": verifier.FOUNDRY_COMMIT,
            },
            "contracts": {
                "order": list(verifier.CONTRACTS),
                "proxies": [f"0x{index + 20:040x}" for index in range(9)],
                "implementations": self.implementations,
                "proxyRuntimeCodehashes": [proxy_hash] * 9,
                "implementationRuntimeCodehashes": implementation_hashes,
            },
            "external": {"usdc": verifier.USDC_DOMAINS[84532]},
            "schemas": {
                "outcome": {"definition": verifier.OUTCOME_SCHEMA},
                "confirmation": {"definition": verifier.CONFIRMATION_SCHEMA},
            },
        }
        self.manifest_path = self.root / "manifest.json"
        self._write_manifest()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_manifest(self) -> None:
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    @patch.object(verifier, "keccak", side_effect=fake_keccak)
    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_verifies_patched_implementations_and_proxy(self, _command, _keccak) -> None:
        evidence = verifier.verify(self.manifest_path, self.output, "forge", "cast")
        self.assertEqual(
            evidence["implementationRuntimeCodehashes"],
            self.manifest["contracts"]["implementationRuntimeCodehashes"],
        )
        self.assertEqual(evidence["proxyRuntimeCodehash"], self.manifest["contracts"]["proxyRuntimeCodehashes"][0])

    @patch.object(verifier, "keccak", side_effect=fake_keccak)
    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_manifest_and_live_pair_that_differs_from_local_build(
        self, _command, _keccak
    ) -> None:
        self.manifest["contracts"]["implementationRuntimeCodehashes"][4] = "0x" + "ab" * 32
        self._write_manifest()
        with self.assertRaisesRegex(verifier.VerificationError, "PaymentRouter implementation runtime hash mismatch"):
            verifier.verify(self.manifest_path, self.output, "forge", "cast")

    @patch.object(verifier, "keccak", side_effect=fake_keccak)
    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_unexpected_immutable(self, _command, _keccak) -> None:
        path = self.output / "AgentIndex.sol" / "AgentIndex.json"
        artifact = json.loads(path.read_text(encoding="utf-8"))
        artifact["deployedBytecode"]["immutableReferences"]["2"] = [{"start": 0, "length": 32}]
        path.write_text(json.dumps(artifact), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "only UUPS __self"):
            verifier.verify(self.manifest_path, self.output, "forge", "cast")

    @patch.object(verifier, "keccak", side_effect=fake_keccak)
    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_noncanonical_proxy(self, _command, _keccak) -> None:
        self.manifest["contracts"]["proxyRuntimeCodehashes"] = ["0x" + "cd" * 32] * 9
        self._write_manifest()
        with self.assertRaisesRegex(verifier.VerificationError, "proxy runtime hash mismatch"):
            verifier.verify(self.manifest_path, self.output, "forge", "cast")

    @patch.object(verifier, "keccak", side_effect=fake_keccak)
    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_foundry_config_hash_mismatch(self, _command, _keccak) -> None:
        with self.assertRaisesRegex(verifier.VerificationError, "Foundry config hash mismatch"):
            verifier.verify(
                self.manifest_path,
                self.output,
                "forge",
                "cast",
                foundry_config_hash="0x" + "44" * 32,
            )

    def test_rejects_wrong_evm_version(self) -> None:
        self.manifest["build"]["evmVersion"] = "prague"
        with self.assertRaisesRegex(verifier.VerificationError, "wrong manifest EVM version"):
            verifier.validate_manifest(self.manifest, FORGE_OUTPUT)

    def test_keccak_streams_large_inputs_to_cast_stdin(self) -> None:
        data = b"x" * 300_000
        completed = subprocess.CompletedProcess(
            ["cast", "keccak"],
            returncode=0,
            stdout=("0x" + "ab" * 32 + "\n").encode(),
            stderr=b"",
        )
        with patch.object(verifier.subprocess, "run", return_value=completed) as run:
            self.assertEqual(verifier.keccak(data, "cast"), "0x" + "ab" * 32)
        run.assert_called_once_with(
            ["cast", "keccak"],
            input=b"0x" + data.hex().encode("ascii"),
            check=False,
            capture_output=True,
        )


class SourceClosureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.required_targets = verifier.REQUIRED_TARGETS
        verifier.REQUIRED_TARGETS = {"A": ("src/A.sol", "A")}
        subprocess.run(["git", "init", "-b", "develop"], cwd=self.repo, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Source Test"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "source@example.com"], cwd=self.repo, check=True)
        source = self.repo / "src" / "A.sol"
        source.parent.mkdir()
        source.write_text("contract A {}\n", encoding="utf-8")
        subprocess.run(["git", "add", "src/A.sol"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-m", "source"], cwd=self.repo, check=True, capture_output=True)
        self.commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.repo, check=True, capture_output=True, text=True
        ).stdout.strip()
        self.output = self.repo / "artifacts"
        artifact_dir = self.output / "A.sol"
        artifact_dir.mkdir(parents=True)
        source_hash = verifier.keccak(source.read_bytes(), "cast")
        self.settings = {
            "optimizer": {"enabled": True, "runs": 200},
            "viaIR": True,
            "evmVersion": verifier.EVM_VERSION,
            "remappings": [],
            "libraries": {},
            "outputSelection": {"src/A.sol": {"A": ["abi"]}},
        }
        self.metadata = {
            "compiler": {"version": verifier.SOLC_VERSION},
            "language": "Solidity",
            "settings": {
                **self.settings,
                "compilationTarget": {"src/A.sol": "A"},
            },
            "sources": {"src/A.sol": {"keccak256": source_hash}},
        }
        self.artifact_path = artifact_dir / "A.json"
        self._write_artifact()
        self.build_info = self.repo / "build-info"
        self.capture_dir = self.build_info / "compiler-inputs"
        self.capture_dir.mkdir(parents=True)
        self.capture_path = self._write_capture({"src/A.sol": {"content": source.read_text(encoding="utf-8")}})

    def tearDown(self) -> None:
        verifier.REQUIRED_TARGETS = self.required_targets
        self.temp.cleanup()

    def _write_artifact(self) -> None:
        self.artifact_path.write_text(
            json.dumps({"metadata": self.metadata, "rawMetadata": json.dumps(self.metadata)}),
            encoding="utf-8",
        )

    def _write_capture(
        self,
        sources: dict[str, dict[str, str]],
        settings: dict | None = None,
        suffix: str = "",
    ) -> Path:
        compiler_input = {
            "language": "Solidity",
            "settings": settings or self.settings,
            "sources": sources,
        }
        digest = hashlib.sha256(
            verifier.canonical_json(compiler_input) + suffix.encode()
        ).hexdigest()
        capture = {
            "schema": "daski-solc-input/v1",
            "compiler": {"version": verifier.SOLC_VERSION},
            "inputSha256": digest,
            "input": compiler_input,
        }
        path = self.capture_dir / f"{digest}.json"
        path.write_text(json.dumps(capture), encoding="utf-8")
        return path

    def test_metadata_remapping_order_is_canonicalized(self) -> None:
        unit = {
            "compiler": {"version": verifier.SOLC_VERSION},
            "settings": {
                **self.settings,
                "remappings": ["b/=lib/b/", "a/=lib/a/"],
            },
        }
        artifact = {
            "metadata": {
                **self.metadata,
                "settings": {
                    **self.metadata["settings"],
                    "remappings": ["a/=lib/a/", "b/=lib/b/"],
                },
            }
        }
        verifier._validate_metadata_against_unit(
            artifact,
            unit,
            {"src/A.sol": self.metadata["sources"]["src/A.sol"]["keccak256"]},
        )

    def test_duplicate_remapping_identity_is_rejected(self) -> None:
        with self.assertRaisesRegex(verifier.VerificationError, "duplicate compiler remapping"):
            verifier._canonical_remappings(["a/=lib/a/", "a/=lib/other/"])

    def test_source_closure_is_bound_to_git_object(self) -> None:
        evidence = verifier.calculate_source_closure(
            self.repo, self.output, self.build_info, self.commit, "cast"
        )
        self.assertEqual(evidence["sources"][0]["repositoryIdentity"], f"root@{self.commit}")
        self.assertEqual(evidence["selectedUnitMapping"]["A"], evidence["compilerUnitHashes"][0])

    def test_untracked_compiler_source_is_rejected(self) -> None:
        source = self.repo / "ignored.sol"
        source.write_text("contract Ignored {}\n", encoding="utf-8")
        self.capture_path.unlink()
        self._write_capture({"ignored.sol": {"content": source.read_text(encoding="utf-8")}})
        with self.assertRaises(verifier.VerificationError):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_worktree_source_cannot_replace_committed_source(self) -> None:
        source = self.repo / "src" / "A.sol"
        source.write_text("contract Replaced {}\n", encoding="utf-8")
        self.capture_path.unlink()
        self._write_capture({"src/A.sol": {"content": source.read_text(encoding="utf-8")}})
        with self.assertRaisesRegex(verifier.VerificationError, "differs from Git object"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_parent_traversal_source_is_rejected(self) -> None:
        self.capture_path.unlink()
        self._write_capture({"../A.sol": {"content": "contract A {}\n"}})
        with self.assertRaisesRegex(verifier.VerificationError, "escapes repository"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_symlink_escape_source_is_rejected(self) -> None:
        link = self.repo / "escape.sol"
        link.symlink_to("/etc/hosts")
        self.capture_path.unlink()
        self._write_capture({"escape.sol": {"content": Path("/etc/hosts").read_text(encoding="utf-8")}})
        with self.assertRaisesRegex(verifier.VerificationError, "escapes repository"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_empty_capture_directory_is_rejected(self) -> None:
        self.capture_path.unlink()
        with self.assertRaisesRegex(verifier.VerificationError, "compiler input is empty"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_unused_compiler_input_is_rejected(self) -> None:
        settings = {**self.settings, "outputSelection": {}, "modelChecker": {}}
        self._write_capture(
            {"src/A.sol": {"content": "contract A {}\n"}},
            settings=settings,
            suffix="unused",
        )
        with self.assertRaisesRegex(verifier.VerificationError, "not used by a required target"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_artifact_settings_must_match_selected_input(self) -> None:
        self.metadata["settings"]["viaIR"] = False
        self._write_artifact()
        with self.assertRaisesRegex(verifier.VerificationError, "artifact viaIR mismatch"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )

    def test_required_target_must_be_selected(self) -> None:
        self.capture_path.unlink()
        settings = {**self.settings, "outputSelection": {}}
        self._write_capture(
            {"src/A.sol": {"content": "contract A {}\n"}},
            settings=settings,
        )
        with self.assertRaisesRegex(verifier.VerificationError, "select exactly one compiler input"):
            verifier.calculate_source_closure(
                self.repo, self.output, self.build_info, self.commit, "cast"
            )


if __name__ == "__main__":
    unittest.main()
