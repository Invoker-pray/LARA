import tempfile
import unittest
from pathlib import Path

import numpy as np

from sw.generate_board_cases import _case_matches, _make_case, _resolve_position_bases


class BoardCaseGenerationTest(unittest.TestCase):
    def test_full_length_case_preserves_absolute_base(self) -> None:
        self.assertEqual(_resolve_position_bases(512, 31, 7), (31, 7))
        self.assertEqual(_resolve_position_bases(128, 3, 3), (3, 3))

    def test_position_range_overflow_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            _resolve_position_bases(128, 65409, 0)
        with self.assertRaises(ValueError):
            _resolve_position_bases(512, 31, 65535)

    def test_case_contains_head_major_raw_bf16_tensors_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = _make_case(
                seq_len=17,
                causal=True,
                q_pos_base=3,
                kv_pos_base=3,
                seed=7,
                output_dir=Path(tmp),
            )
            with np.load(path) as data:
                self.assertEqual(data["q_heads"].shape, (32, 17, 128))
                self.assertEqual(data["k_heads"].shape, (8, 17, 128))
                self.assertEqual(data["v_heads"].shape, (8, 17, 128))
                self.assertEqual(data["expected_o"].shape, (32, 17, 128))
                self.assertEqual(data["q_heads"].dtype, np.uint16)
                self.assertEqual(int(data["q_pos_base"]), 3)
                self.assertEqual(int(data["kv_pos_base"]), 3)

    def test_resume_requires_matching_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output_dir = Path(tmp)
            path = _make_case(
                seq_len=1,
                causal=False,
                q_pos_base=31,
                kv_pos_base=7,
                seed=9,
                output_dir=output_dir,
            )
            self.assertTrue(_case_matches(
                path,
                seq_len=1,
                causal=False,
                q_pos_base=31,
                kv_pos_base=7,
                seed=9,
            ))
            self.assertFalse(_case_matches(
                path,
                seq_len=1,
                causal=False,
                q_pos_base=31,
                kv_pos_base=7,
                seed=10,
            ))


if __name__ == "__main__":
    unittest.main()
