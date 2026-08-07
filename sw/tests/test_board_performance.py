import csv
import tempfile
import unittest
from pathlib import Path

import numpy as np

from sw.attn_driver import (
    HEAD_DIM,
    N_KV_HEADS,
    N_Q_HEADS,
    PL_CLOCK_MHZ,
    fp32_to_bf16_u16,
)
from sw.board_performance import (
    BoardCase,
    FreshOverlayRunner,
    _resolve_case_sets,
    _stats,
    _write_csv,
    benchmark_case,
    cpu_attention_numpy,
    discover_cases,
)


class BoardPerformanceTest(unittest.TestCase):
    def test_case_sets_are_explicitly_resolved_and_labels_are_unique(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            resolved = _resolve_case_sets([("custom", directory)])
            self.assertEqual(resolved, [("custom", directory.resolve())])
            with self.assertRaisesRegex(ValueError, "duplicate case-set label"):
                _resolve_case_sets([
                    ("custom", directory),
                    ("custom", directory / "second"),
                ])

    def test_fresh_overlay_runner_closes_each_sample_and_preserves_profile(self):
        instances = []

        class FakeAccelerator:
            hw_ready = True

            def __init__(self, bitstream):
                self.bitstream = bitstream
                self.last_profile = None
                self.closed = False
                instances.append(self)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.closed = True

            def run_attention(self, value):
                self.last_profile = {"sample": len(instances)}
                return np.asarray([value])

        runner = FreshOverlayRunner(Path("test.bit"), FakeAccelerator)
        np.testing.assert_array_equal(runner.run_attention(1), np.asarray([1]))
        np.testing.assert_array_equal(runner.run_attention(2), np.asarray([2]))
        self.assertEqual(len(instances), 2)
        self.assertTrue(all(instance.closed for instance in instances))
        self.assertEqual(runner.last_profile, {"sample": 2})

    def test_zero_pl_counter_keeps_host_timing_results(self):
        class FakeProfile:
            def to_dict(self):
                return {
                    "clock_mhz": PL_CLOCK_MHZ,
                    "pl_total_cycles": 0,
                    "pl_mac_cycles": 0,
                    "pl_stall_cycles": 0,
                    "attention_total_ms": 1.25,
                }

        class FakeAccelerator:
            last_profile = None

            def run_attention(self, q, k, v, **kwargs):
                self.last_profile = FakeProfile()
                return q.copy()

        with tempfile.TemporaryDirectory() as tmp:
            case_path = Path(tmp) / "case.npz"
            case_path.write_bytes(b"case provenance")
            q = np.zeros((N_Q_HEADS, 1, HEAD_DIM), dtype=np.uint16)
            kv = np.zeros((N_KV_HEADS, 1, HEAD_DIM), dtype=np.uint16)
            case = BoardCase("test", case_path, q, kv, kv, q, 1, True, 0, 0)

            result = benchmark_case(
                FakeAccelerator(), case, warmup=0, repeats=1, timeout_ms=None,
                cpu_clock_mhz=1000.0,
            )

        self.assertTrue(result["correctness"]["fpga_bit_exact_expected"])
        self.assertFalse(result["fpga"]["pl_counter_valid"])
        self.assertIsNone(result["fpga"]["pl_total_cycles_stats"])
        self.assertIsNone(result["fpga"]["pl_transaction_ms_from_cycles"])
        self.assertIsNone(result["fpga"]["pl_core_active_ms_excluding_stalls"])
        self.assertNotIn("speedup", result)
        self.assertNotIn("architecture_per_cycle", result)
        self.assertIsNotNone(result["cpu_baseline"]["estimated_cycles_stats"])
        self.assertEqual(result["fpga"]["host_to_host_attention_ms"]["median"], 1.25)

    def test_valid_pl_counters_split_transaction_compute_and_stall(self):
        class FakeProfile:
            def to_dict(self):
                return {
                    "clock_mhz": PL_CLOCK_MHZ,
                    "pl_total_cycles": 1000,
                    "pl_mac_cycles": 600,
                    "pl_stall_cycles": 200,
                    "attention_total_ms": 2.0,
                }

        class FakeAccelerator:
            last_profile = None

            def run_attention(self, q, k, v, **kwargs):
                self.last_profile = FakeProfile()
                return q.copy()

        with tempfile.TemporaryDirectory() as tmp:
            case_path = Path(tmp) / "case.npz"
            case_path.write_bytes(b"case provenance")
            q = np.zeros((N_Q_HEADS, 1, HEAD_DIM), dtype=np.uint16)
            kv = np.zeros((N_KV_HEADS, 1, HEAD_DIM), dtype=np.uint16)
            case = BoardCase("test", case_path, q, kv, kv, q, 1, True, 0, 0)
            result = benchmark_case(
                FakeAccelerator(), case, warmup=0, repeats=1, timeout_ms=None,
                cpu_clock_mhz=1000.0,
            )

        cycles_per_ms = PL_CLOCK_MHZ * 1000.0
        self.assertTrue(result["fpga"]["pl_counter_valid"])
        self.assertEqual(
            result["fpga"]["pl_core_active_cycles_excluding_stalls"], [800],
        )
        self.assertAlmostEqual(
            result["fpga"]["pl_transaction_ms_from_cycles"]["median"],
            1000 / cycles_per_ms,
        )
        self.assertAlmostEqual(
            result["fpga"]["pl_core_active_ms_excluding_stalls"]["median"],
            800 / cycles_per_ms,
        )
        self.assertAlmostEqual(
            result["fpga"]["pl_mac_active_ms_from_cycles"]["median"],
            600 / cycles_per_ms,
        )
        cpu = result["cpu_baseline"]
        self.assertEqual(cpu["cpu_clock_mhz"], 1000.0)
        self.assertGreater(cpu["estimated_cycles_stats"]["median"], 0)
        self.assertNotIn("speedup", result)

        with tempfile.TemporaryDirectory() as tmp:
            csv_path = Path(tmp) / "measurements.csv"
            _write_csv(csv_path, [result])
            with csv_path.open(newline="", encoding="utf-8") as stream:
                row = next(csv.DictReader(stream))
        self.assertEqual(row["fpga_bit_exact"], "True")
        self.assertIn("pl_cycles_median", row)
        self.assertIn("fpga_e2e_ms_median", row)
        self.assertIn("cpu_ms_median", row)
        self.assertIn("cpu_estimated_cycles_median", row)
        for forbidden in (
            "speedup_pl",
            "speedup_e2e",
            "pl_effective_gops",
            "cpu_effective_gops",
            "pl_active_ops_per_cycle",
        ):
            self.assertNotIn(forbidden, row)

    def test_cpu_baseline_uniform_attention(self):
        length = 4
        q = np.zeros((N_Q_HEADS, length, HEAD_DIM), dtype=np.uint16)
        k = np.zeros((N_KV_HEADS, length, HEAD_DIM), dtype=np.uint16)
        values = np.arange(length, dtype=np.float32)[:, None]
        v_float = np.broadcast_to(values, (length, HEAD_DIM))
        v = np.broadcast_to(fp32_to_bf16_u16(v_float), (N_KV_HEADS, length, HEAD_DIM)).copy()

        noncausal = cpu_attention_numpy(q, k, v, causal=False, q_pos_base=3, kv_pos_base=3)
        self.assertTrue(np.allclose(noncausal, 1.5))

        causal = cpu_attention_numpy(q, k, v, causal=True, q_pos_base=3, kv_pos_base=3)
        for row, expected in enumerate((0.0, 0.5, 1.0, 1.5)):
            self.assertTrue(np.allclose(causal[:, row, :], expected))

    def test_position_offset_causal_mask(self):
        length = 3
        q = np.zeros((N_Q_HEADS, length, HEAD_DIM), dtype=np.uint16)
        k = np.zeros((N_KV_HEADS, length, HEAD_DIM), dtype=np.uint16)
        values = np.arange(length, dtype=np.float32)[:, None]
        v = np.broadcast_to(
            fp32_to_bf16_u16(np.broadcast_to(values, (length, HEAD_DIM))),
            (N_KV_HEADS, length, HEAD_DIM),
        ).copy()
        output = cpu_attention_numpy(q, k, v, causal=True, q_pos_base=2, kv_pos_base=0)
        self.assertTrue(np.allclose(output, 1.0))

    def test_statistics(self):
        stats = _stats([1.0, 2.0, 3.0])
        self.assertEqual(stats["min"], 1.0)
        self.assertEqual(stats["median"], 2.0)
        self.assertEqual(stats["max"], 3.0)

    def test_discovery_requires_full_l1_to_l128_matrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            q = np.zeros((N_Q_HEADS, 1, HEAD_DIM), dtype=np.uint16)
            k = np.zeros((N_KV_HEADS, 1, HEAD_DIM), dtype=np.uint16)
            np.savez(
                directory / "case_L1_causal.npz",
                q_heads=q, k_heads=k, v_heads=k, expected_o=q,
                seq_len=np.uint16(1), causal=np.uint8(1),
            )
            with self.assertRaisesRegex(ValueError, "missing required cases"):
                discover_cases([("incomplete", directory)])


if __name__ == "__main__":
    unittest.main()
