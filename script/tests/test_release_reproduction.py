import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_release_reproductions as comparator


class ReleaseReproductionComparisonTest(unittest.TestCase):
    def setUp(self) -> None:
        self.evidence = {
            "schema": "daski-release-reproduction/v1",
            **{field: {"value": field} for field in comparator.FIELDS},
        }

    def test_accepts_exact_reproductions(self) -> None:
        comparator.compare(self.evidence, dict(self.evidence))

    def test_rejects_any_release_field_difference(self) -> None:
        for field in comparator.FIELDS:
            with self.subTest(field=field):
                changed = dict(self.evidence)
                changed[field] = {"changed": field}
                with self.assertRaisesRegex(ValueError, field):
                    comparator.compare(self.evidence, changed)

    def test_rejects_old_schema(self) -> None:
        changed = dict(self.evidence)
        changed["schema"] = "daski-release-reproduction/v0"
        with self.assertRaisesRegex(ValueError, "schema mismatch"):
            comparator.compare(self.evidence, changed)


if __name__ == "__main__":
    unittest.main()
