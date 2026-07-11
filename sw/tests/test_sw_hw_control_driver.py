import pathlib
import sys
import unittest

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sw import attn_driver as drv


class SwHwControlDriverTest(unittest.TestCase):
    def make_inputs(self, seq_len: int):
        q = np.arange(drv.N_Q_HEADS * seq_len * drv.HEAD_DIM, dtype=np.uint16).reshape(
            drv.N_Q_HEADS, seq_len, drv.HEAD_DIM
        )
        k = np.arange(drv.N_KV_HEADS * seq_len * drv.HEAD_DIM, dtype=np.uint16).reshape(
            drv.N_KV_HEADS, seq_len, drv.HEAD_DIM
        )
        v = (np.arange(drv.N_KV_HEADS * seq_len * drv.HEAD_DIM, dtype=np.uint16) ^ 0x55AA).reshape(
            drv.N_KV_HEADS, seq_len, drv.HEAD_DIM
        )
        return q, k, v

    def test_byte_counts(self):
        counts = drv.AttentionAccelerator.byte_counts(16)
        self.assertEqual(counts.q_bytes, 32 * 16 * 128 * 2)
        self.assertEqual(counts.k_bytes, 8 * 16 * 128 * 2)
        self.assertEqual(counts.v_bytes, counts.k_bytes)
        self.assertEqual(counts.o_bytes, counts.q_bytes)

    def test_reject_bad_shape(self):
        accel = drv.AttentionAccelerator()
        bad_q = np.zeros((16, 16, drv.HEAD_DIM), dtype=np.uint16)
        k = np.zeros((drv.N_KV_HEADS, 16, drv.HEAD_DIM), dtype=np.uint16)
        v = np.zeros((drv.N_KV_HEADS, 16, drv.HEAD_DIM), dtype=np.uint16)
        with self.assertRaises(ValueError):
            accel.run_attention(bad_q, k, v, seq_len=16)

    def test_full_run_trace_single_start(self):
        seq_len = 4
        q, k, v = self.make_inputs(seq_len)
        accel = drv.AttentionAccelerator()
        out = accel.run_attention(q, k, v, seq_len=seq_len, q_pos_base=1, kv_pos_base=1, causal=True)
        self.assertEqual(out.shape, (drv.N_Q_HEADS, seq_len, drv.HEAD_DIM))

        writes = [entry for entry in accel.mmio.trace if entry[0] == "write"]
        reads = [entry for entry in accel.mmio.trace if entry[0] == "read"]
        write_offsets = [entry[1] for entry in writes]
        write_values = [(entry[1], entry[2]) for entry in writes]

        expected_prefix = [
            drv.CSR_SEQ_LEN,
            drv.CSR_Q_POS_BASE,
            drv.CSR_KV_POS_BASE,
            drv.CSR_CFG,
            drv.CSR_CTRL,
            drv.CSR_STREAM_DEST,
            drv.CSR_STREAM_LEN,
            drv.CSR_STREAM_DEST,
            drv.CSR_STREAM_LEN,
            drv.CSR_STREAM_DEST,
            drv.CSR_STREAM_LEN,
            drv.CSR_RESULT_LEN,
            drv.CSR_CTRL,
        ]
        self.assertEqual(write_offsets[: len(expected_prefix)], expected_prefix)
        self.assertEqual(write_values[5], (drv.CSR_STREAM_DEST, drv.DEST_K_CACHE))
        self.assertEqual(write_values[7], (drv.CSR_STREAM_DEST, drv.DEST_V_CACHE))
        self.assertEqual(write_values[9], (drv.CSR_STREAM_DEST, drv.DEST_Q_BUF))
        self.assertEqual(write_values[6], (drv.CSR_STREAM_LEN, drv.N_KV_HEADS * seq_len * drv.HEAD_DIM * 2))
        self.assertEqual(write_values[8], (drv.CSR_STREAM_LEN, drv.N_KV_HEADS * seq_len * drv.HEAD_DIM * 2))
        self.assertEqual(write_values[10], (drv.CSR_STREAM_LEN, drv.N_Q_HEADS * seq_len * drv.HEAD_DIM * 2))
        self.assertEqual(write_values[11], (drv.CSR_RESULT_LEN, drv.N_Q_HEADS * seq_len * drv.HEAD_DIM * 2))
        self.assertEqual(write_values[12], (drv.CSR_CTRL, drv.CTRL_START))
        self.assertEqual(sum(1 for off, val in write_values if off == drv.CSR_CTRL and val == drv.CTRL_START), 1)
        self.assertTrue(any(entry[1] == drv.CSR_STATUS for entry in reads), "driver must read status before/during start")

        send_trace = accel.dma_send.trace
        recv_trace = accel.dma_recv.trace
        self.assertEqual(send_trace, [
            ("transfer", "send", drv.N_KV_HEADS * seq_len * drv.HEAD_DIM * 2),
            ("wait", "send", 0),
            ("transfer", "send", drv.N_KV_HEADS * seq_len * drv.HEAD_DIM * 2),
            ("wait", "send", 0),
            ("transfer", "send", drv.N_Q_HEADS * seq_len * drv.HEAD_DIM * 2),
            ("wait", "send", 0),
        ])
        self.assertEqual(recv_trace, [
            ("transfer", "recv", drv.N_Q_HEADS * seq_len * drv.HEAD_DIM * 2),
            ("wait", "recv", 0),
        ])


if __name__ == "__main__":
    unittest.main()