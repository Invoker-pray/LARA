"""Unit tests for the executable LARA v2.5 P4 DSE model."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "p4_dse.py"
SPEC = importlib.util.spec_from_file_location("p4_dse", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
p4_dse = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p4_dse)


class P4DseTest(unittest.TestCase):
    def test_phaseb_16x16_matches_synthesis_profile(self) -> None:
        model = p4_dse.phaseb_model()
        self.assertEqual(model["tasks"], 64)
        self.assertEqual(model["run_cycles_per_task"], 32)
        self.assertEqual(model["total_cycles"], 3_136)

        measured = p4_dse.PROFILE_32X32
        self.assertEqual(measured["phaseb_run_cycles"], 1_024)
        self.assertEqual(measured["phaseb_capture_cycles"], 32)
        self.assertEqual(measured["phaseb_update_cycles"], 512)

    def test_phaseb_16x32_reduces_both_block_dimensions(self) -> None:
        model = p4_dse.phaseb_model(tile_cols=32)
        self.assertEqual(model["kv_subblocks"], 2)
        self.assertEqual(model["dim_subblocks"], 4)
        self.assertEqual(model["tasks"], 16)
        self.assertEqual(model["total_cycles"], 1_296)

    def test_candidate_decisions_follow_p4_gates(self) -> None:
        model = p4_dse.build_model()
        candidates = model["candidates"]
        self.assertEqual(
            candidates["streaming_fused_pv"]["decision"], "advance-to-rtl"
        )
        self.assertGreater(
            candidates["streaming_fused_pv"]["cycle_model"][
                "measured_reduction_percent"
            ],
            10.0,
        )
        self.assertEqual(
            candidates["dual_softmax"]["decision"], "reject-resource-model"
        )
        self.assertGreater(
            candidates["dual_softmax"]["resource_projection"]["lut_percent"],
            90.0,
        )
        self.assertEqual(
            candidates["mac_16x32"]["decision"], "reject-resource-model"
        )
        self.assertGreater(
            candidates["mac_16x32"]["resource_lower_bound"][
                "top_lut_percent"
            ],
            100.0,
        )

    def test_model_never_calls_model_only_candidate_accepted(self) -> None:
        model = p4_dse.build_model()
        for candidate in model["candidates"].values():
            self.assertNotEqual(candidate["acceptance_state"], "accepted")


if __name__ == "__main__":
    unittest.main()
