import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from sw.run_board_full_validation import (
    _functional_summary,
    _performance_summary,
    _require_empty_output,
    _resolve_case_sets,
    _select_case_set,
    main,
)


class RunBoardFullValidationTest(unittest.TestCase):
    def test_main_forwards_explicit_case_paths_and_lengths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in (
                "lara_attention.bit",
                "lara_attention.hwh",
                "lara_attention.xsa",
                "attn_driver.py",
                "board_matrix.py",
                "board_performance.py",
            ):
                (root / name).touch()
            q3_cases = root / "external" / "q3"
            q31_cases = root / "external" / "q31"
            q3_cases.mkdir(parents=True)
            q31_cases.mkdir(parents=True)
            commands: list[list[str]] = []

            def fake_run(command, log_path, *, env=None):
                del log_path, env
                commands.append(command)
                output = Path(command[command.index("--output-dir") + 1])
                output.mkdir(parents=True, exist_ok=True)
                if command[1].endswith("board_matrix.py"):
                    (output / "summary.json").write_text(
                        json.dumps([{"status": "PASS"} for _ in range(4)]),
                        encoding="utf-8",
                    )
                else:
                    (output / "performance.json").write_text(
                        json.dumps({
                            "results": [
                                {"correctness": {"fpga_bit_exact_expected": True}}
                                for _ in range(8)
                            ],
                            "benchmark_errors": [],
                        }),
                        encoding="utf-8",
                    )
                return {"return_code": 0, "status": "PASS"}

            argv = [
                "run_board_full_validation.py",
                "--bitstream", str(root / "lara_attention.bit"),
                "--case-set", f"q3kv3={q3_cases}",
                "--case-set", f"q31kv7={q31_cases}",
                "--lengths", "1", "128",
                "--output-dir", str(root / "results"),
                "--warmup", "0",
                "--repeats", "1",
                "--allow-missing-init-report",
            ]
            previous_cwd = Path.cwd()
            try:
                os.chdir(root)
                with (
                    patch.object(sys, "argv", argv),
                    patch(
                        "sw.run_board_full_validation._run_logged",
                        side_effect=fake_run,
                    ),
                ):
                    self.assertEqual(main(), 0)
            finally:
                os.chdir(previous_cwd)

            self.assertEqual(len(commands), 3)
            self.assertIn(str(q3_cases.resolve()), commands[0])
            self.assertIn(str(q31_cases.resolve()), commands[1])
            for command in commands:
                lengths_index = command.index("--lengths")
                self.assertEqual(command[lengths_index + 1:lengths_index + 3], ["1", "128"])
            self.assertIn(f"q3kv3={q3_cases.resolve()}", commands[2])
            self.assertIn(f"q31kv7={q31_cases.resolve()}", commands[2])

    def test_case_sets_are_explicit_paths_and_quick_mode_selects_q31kv7(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resolved = _resolve_case_sets([
                ("q3kv3", root / "cases-a"),
                ("q31kv7", root / "cases-b"),
            ])
            self.assertEqual(
                _select_case_set(resolved, "q31kv7"),
                (("q31kv7", (root / "cases-b").resolve()),),
            )

    def test_duplicate_or_missing_required_case_set_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            with self.assertRaisesRegex(ValueError, "duplicate case-set label"):
                _resolve_case_sets([
                    ("q31kv7", directory),
                    ("q31kv7", directory),
                ])
            with self.assertRaisesRegex(ValueError, "requires --case-set q31kv7"):
                _select_case_set(
                    _resolve_case_sets([("custom", directory)]),
                    "q31kv7",
                )

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
