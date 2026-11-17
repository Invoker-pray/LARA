from pathlib import Path
import unittest
from unittest.mock import patch

from sw.benchmark_host_cpu import default_case_sets, frequency_estimate, choose_core


class HostCpuBenchmarkTest(unittest.TestCase):
    def test_constant_frequency_normalization_units(self):
        r = frequency_estimate([(0, 2000.0), (10_000_000, 2000.0)], 0, 10_000_000, 100.0)
        self.assertEqual(r['estimated_cycles'], 20_000_000)
        self.assertEqual(r['normalized_wall_ms'], 200.0)

    def test_dynamic_frequency_and_interval_clipping(self):
        r = frequency_estimate([(0, 1000.0), (20_000_000, 3000.0)], 5_000_000, 15_000_000, 100.0)
        self.assertEqual(r['time_weighted_mhz'], 2000.0)
        self.assertEqual(r['normalized_wall_ms'], 200.0)

    def test_missing_frequency_is_not_a_valid_estimate(self):
        self.assertFalse(frequency_estimate([(0, None), (10, 2000.0)], 0, 10, 100.0)['valid'])
        self.assertFalse(frequency_estimate([], 0, 10, 100.0)['valid'])

    def test_automatic_cases_have_distinct_position_groups(self):
        sets = default_case_sets(Path('/repo'))
        self.assertEqual(sets[0], ('q31kv7', Path('/repo/board_cases_rtl_contract_v2.6_q31_kv7')))
        self.assertEqual(sets[1], ('q3kv3', Path('/repo/board_cases_rtl_contract_v2.6_q3_kv3')))

    def test_core_selection_prefers_highest_supported_maximum(self):
        with patch('sw.benchmark_host_cpu.Path.read_text', side_effect=['3500000', '4700000']):
            self.assertEqual(choose_core({2, 3}), 3)


if __name__ == '__main__':
    unittest.main()
