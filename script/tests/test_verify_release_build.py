import hashlib
import json
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
            "build": {
                "sourceCommit": "1" * 40,
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

    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_verifies_patched_implementations_and_proxy(self, _command) -> None:
        evidence = verifier.verify(self.manifest_path, self.output, "forge", "cast")
        self.assertEqual(
            evidence["implementationRuntimeCodehashes"],
            self.manifest["contracts"]["implementationRuntimeCodehashes"],
        )
        self.assertEqual(evidence["proxyRuntimeCodehash"], self.manifest["contracts"]["proxyRuntimeCodehashes"][0])

    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_manifest_and_live_pair_that_differs_from_local_build(self, _command) -> None:
        self.manifest["contracts"]["implementationRuntimeCodehashes"][4] = "0x" + "ab" * 32
        self._write_manifest()
        with self.assertRaisesRegex(verifier.VerificationError, "PaymentRouter implementation runtime hash mismatch"):
            verifier.verify(self.manifest_path, self.output, "forge", "cast")

    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_unexpected_immutable(self, _command) -> None:
        path = self.output / "AgentIndex.sol" / "AgentIndex.json"
        artifact = json.loads(path.read_text(encoding="utf-8"))
        artifact["deployedBytecode"]["immutableReferences"]["2"] = [{"start": 0, "length": 32}]
        path.write_text(json.dumps(artifact), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "only UUPS __self"):
            verifier.verify(self.manifest_path, self.output, "forge", "cast")

    @patch.object(verifier, "command_output", side_effect=fake_command)
    def test_rejects_noncanonical_proxy(self, _command) -> None:
        self.manifest["contracts"]["proxyRuntimeCodehashes"] = ["0x" + "cd" * 32] * 9
        self._write_manifest()
        with self.assertRaisesRegex(verifier.VerificationError, "proxy runtime hash mismatch"):
            verifier.verify(self.manifest_path, self.output, "forge", "cast")

    def test_rejects_wrong_evm_version(self) -> None:
        self.manifest["build"]["evmVersion"] = "prague"
        with self.assertRaisesRegex(verifier.VerificationError, "wrong manifest EVM version"):
            verifier.validate_manifest(self.manifest, FORGE_OUTPUT)


if __name__ == "__main__":
    unittest.main()
