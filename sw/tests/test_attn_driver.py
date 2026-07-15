import unittest

import numpy as np

from sw.attn_driver import (
    AttentionAccelerator,
    HEAD_DIM,
    N_KV_HEADS,
    N_Q_HEADS,
    TILE_Q,
    bf16_u16_to_fp32,
    fp32_to_bf16_u16,
)


class AttentionDriverTest(unittest.TestCase):
    def test_bf16_round_trip(self):
        values = np.array([1.0, -2.5, 0.0, np.float32(1.0 / 3.0)], dtype=np.float32)
        words = fp32_to_bf16_u16(values)
        self.assertEqual(words.dtype, np.uint16)
        self.assertEqual(words[0], 0x3F80)
        self.assertEqual(words[1], 0xC020)
        self.assertTrue(np.allclose(bf16_u16_to_fp32(words), values, rtol=8e-3, atol=1e-3))

    def test_request_service_reuses_kv_per_group(self):
        seq_len = 33
        q = np.zeros((N_Q_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
        k = np.zeros((N_KV_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
        v = np.zeros_like(k)
        accel = AttentionAccelerator()
        out = accel.run_attention(q, k, v, seq_len=seq_len)
        self.assertEqual(out.shape, (N_Q_HEADS, seq_len, HEAD_DIM))
        transfers = [entry for entry in accel.dma_send.trace if entry[0] == "transfer"]
        expected = N_KV_HEADS * 2 + N_Q_HEADS * ((seq_len + TILE_Q - 1) // TILE_Q)
        self.assertEqual(len(transfers), expected)
        self.assertEqual(transfers[0][2], N_KV_HEADS * 0 + seq_len * HEAD_DIM * 2)
        self.assertEqual(transfers[1][2], seq_len * HEAD_DIM * 2)

    def test_rejects_wrong_layout(self):
        accel = AttentionAccelerator()
        with self.assertRaises(ValueError):
            accel.run_attention(
                np.zeros((1, 4, HEAD_DIM), dtype=np.uint16),
                np.zeros((N_KV_HEADS, 4, HEAD_DIM), dtype=np.uint16),
                np.zeros((N_KV_HEADS, 4, HEAD_DIM), dtype=np.uint16),
                seq_len=4,
            )


if __name__ == "__main__":
    unittest.main()
