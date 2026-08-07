import json
import tempfile
import unittest
from pathlib import Path

from sw.run_board_full_validation import (
    _functional_summary,
    _performance_summary,
    _require_empty_output,
)


class RunBoardFullValidationTest(unittest.TestCase):
    def test_functional_summary_requires_ten_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "summary.json"
            path.write_text(
                json.dumps([{"status": "PASS"} for _ in range(10)]),
                encoding="utf-8",
            )
            self.assertTrue(_functional_summary(path)["all_passed"])

    def test_performance_summary_requires_twenty_bit_exact_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "performance.json"
            path.write_text(
                json.dumps({
                    "results": [
                        {"correctness": {"fpga_bit_exact_expected": True}}
                        for _ in range(20)
                    ],
                    "benchmark_errors": [],
                }),
                encoding="utf-8",
            )
            self.assertTrue(_performance_summary(path)["all_passed"])

    def test_nonempty_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / "old.txt").write_text("old", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                _require_empty_output(path)


if __name__ == "__main__":
    unittest.main()
