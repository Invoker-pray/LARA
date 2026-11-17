import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from sw.benchmark_cpu_bf16 import matched_cpu_clock, normalize_cpu_samples
from sw.board_performance import load_case
from python_godel.attention_rtl_golden import attention_gqa_rtl_vectorized
from python_godel.attention_rtl_golden import (
    exp_lookup_bits, exp_lookup_bits_array, load_exp_lut,
)


class CpuBf16BenchmarkTest(unittest.TestCase):
    def test_vectorized_exp_matches_scalar_across_lut_range(self):
        root = Path(__file__).resolve().parents[2]
        lut = load_exp_lut(root/'VV/data/exp_lut.hex')
        values = np.linspace(-8.1, 0.1, 2051, dtype=np.float32).view(np.uint32)
        expected = np.array([exp_lookup_bits(int(v), lut) for v in values], dtype=np.uint32)
        np.testing.assert_array_equal(exp_lookup_bits_array(values, np.asarray(lut)), expected)

    def test_normalization_units_and_frequency_change(self):
        r = normalize_cpu_samples([2.0], [1000.0], [1000.0], 50.0)
        self.assertEqual(r['estimated_cycles']['median'], 2_000_000)
        self.assertEqual(r['normalized_wall_ms']['median'], 40.0)
        self.assertFalse(normalize_cpu_samples([2.0], [1000.0], [900.0], 50.0)['valid'])
        self.assertFalse(normalize_cpu_samples([2.0], [None], [None], 50.0)['valid'])

    def test_unsupported_clock_does_not_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p/'scaling_available_frequencies').write_text('333333 1333333')
            (p/'scaling_available_governors').write_text('userspace performance')
            (p/'scaling_governor').write_text('performance')
            with patch('sw.benchmark_cpu_bf16.Path', return_value=p):
                with matched_cpu_clock(3, 71.428, True) as status:
                    self.assertFalse(status['matched'])
            self.assertEqual((p/'scaling_governor').read_text(), 'performance')

    def test_supported_clock_restored_after_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            for name, value in {'scaling_available_frequencies': '71428 1333333',
                                'scaling_available_governors': 'userspace performance',
                                'scaling_governor': 'userspace',
                                'scaling_setspeed': '1333333'}.items():
                (p/name).write_text(value)
            with patch('sw.benchmark_cpu_bf16.Path', return_value=p), \
                 patch('sw.benchmark_cpu_bf16.detect_cpu_clock_mhz', return_value=71.428):
                with self.assertRaisesRegex(RuntimeError, 'test interrupt'):
                    with matched_cpu_clock(3, 71.428, True) as status:
                        self.assertTrue(status['matched'])
                        raise RuntimeError('test interrupt')
            self.assertEqual((p/'scaling_setspeed').read_text(), '1333333')
            self.assertEqual((p/'scaling_governor').read_text(), 'userspace')

    def test_l1_matches_existing_raw_bf16_case(self):
        root = Path(__file__).resolve().parents[2]
        case = load_case('q31', root/'board_cases_rtl_contract_v2.6_q31_kv7/case_L1_q31_kv7_causal.npz')
        result = attention_gqa_rtl_vectorized(case.q, case.k, case.v,
            causal=case.causal, q_pos_base=case.q_pos_base, kv_pos_base=case.kv_pos_base,
            exp_lut_path=root/'VV/data/exp_lut.hex', recip_lut_path=root/'VV/data/recip_lut.hex')
        np.testing.assert_array_equal(result, case.expected)


if __name__ == '__main__':
    unittest.main()
