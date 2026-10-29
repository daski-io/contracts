"""The artifact path must preserve the ABI and storage gates without compiling."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from check_storage_layout import CONTRACTS, LayoutError, inspect
from export_release_build import ABI_CONTRACTS, export_abis


class BuildExportsTest(unittest.TestCase):
    def test_abi_export_reads_all_seven_compiled_contracts(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ABI_CONTRACTS:
                path = root / "out" / f"{name}.sol" / f"{name}.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps({"abi": [{"type": "function", "name": name}]}))
            export_abis(root / "out", root / "abi")
            self.assertEqual({p.stem for p in (root / "abi").glob("*.json")}, set(ABI_CONTRACTS))
            for name in ABI_CONTRACTS:
                self.assertEqual(json.loads((root / "abi" / f"{name}.json").read_text()),
                                 [{"type": "function", "name": name}])
            path.write_text('{"abi": []}')
            with self.assertRaisesRegex(SystemExit, "non-empty ABI"):
                export_abis(root / "out", root / "bad-abi")
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                export_abis(root / "out", root / "missing-abi")

    def test_artifact_layout_matches_inspection_and_rejects_unsafe_storage(self):
        types = {
            "address": {"encoding": "inplace", "label": "address", "numberOfBytes": "20"},
            "bool": {"encoding": "inplace", "label": "bool", "numberOfBytes": "1"},
            "gap": {"encoding": "inplace", "label": "uint256[47]", "numberOfBytes": "1504"},
        }
        from check_storage_layout import FIRST_DERIVED_STORAGE
        with TemporaryDirectory() as directory:
            root = Path(directory)
            layouts = []
            for name in CONTRACTS:
                slot, label = FIRST_DERIVED_STORAGE[name]
                layout = {"types": types, "storage": [
                    {"label": "pauseGuardian", "slot": "52", "offset": 0, "type": "address"},
                    {"label": "externalDependencyPaused", "slot": "52", "offset": 20, "type": "bool"},
                    {"label": "__gap", "slot": "53", "offset": 0, "type": "gap"},
                    {"label": label, "slot": slot, "offset": 0, "type": "address"},
                ]}
                layouts.append(layout)
                path = root / f"{name}.sol" / f"{name}.json"
                path.parent.mkdir()
                path.write_text(json.dumps({"storageLayout": layout}))
            with patch("check_storage_layout.subprocess.run") as run:
                run.side_effect = [type("Result", (), {"returncode": 0, "stdout": json.dumps(l), "stderr": ""})
                                   for l in layouts]
                expected = inspect(root, "forge")
            with patch("check_storage_layout.subprocess.run", side_effect=AssertionError("must not compile")):
                self.assertEqual(inspect(root, "forge", root), expected)
                layouts[-1]["storage"][0]["slot"] = "51"
                path.write_text(json.dumps({"storageLayout": layouts[-1]}))
                with self.assertRaises(LayoutError):
                    inspect(root, "forge", root)
                path.write_text('{}')
                with self.assertRaises(KeyError):
                    inspect(root, "forge", root)


if __name__ == "__main__":
    unittest.main()
