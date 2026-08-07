import unittest

import numpy as np

from sw.attn_driver import (
    AttentionAccelerator,
    DMA_MAX_TRANSFER_BYTES,
    HEAD_DIM,
    MAX_KV_HEAD_BYTES,
    MAX_OUTPUT_BYTES,
    N_KV_HEADS,
    N_Q_HEADS,
    Q_TILE_BYTES,
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

    def test_maximum_transfer_sizes_and_reusable_buffers(self):
        seq_len = 512
        q = np.zeros((N_Q_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
        k = np.zeros((N_KV_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
        v = np.zeros_like(k)
        accel = AttentionAccelerator()
        buffer_ids = (id(accel._kv_send_buf), id(accel._q_send_buf), id(accel._out_buf))

        out = accel.run_attention(q, k, v, seq_len=seq_len)

        self.assertEqual(out.nbytes, MAX_OUTPUT_BYTES)
        self.assertLessEqual(MAX_OUTPUT_BYTES, DMA_MAX_TRANSFER_BYTES)
        self.assertEqual(accel._kv_send_buf.nbytes, MAX_KV_HEAD_BYTES)
        self.assertEqual(accel._q_send_buf.nbytes, Q_TILE_BYTES)
        self.assertEqual(accel._out_buf.nbytes, MAX_OUTPUT_BYTES)
        self.assertEqual(buffer_ids, (id(accel._kv_send_buf), id(accel._q_send_buf), id(accel._out_buf)))
        self.assertEqual(accel.dma_send.trace[0][2], MAX_KV_HEAD_BYTES)
        self.assertEqual(accel.dma_recv.trace[0][2], MAX_OUTPUT_BYTES)

        profile = accel.last_profile
        self.assertIsNotNone(profile)
        assert profile is not None
        self.assertEqual(profile.kv_dma_transfers, N_KV_HEADS * 2)
        self.assertEqual(profile.q_dma_transfers, N_Q_HEADS * (seq_len // TILE_Q))
        self.assertEqual(profile.output_dma_bytes, MAX_OUTPUT_BYTES)
        self.assertEqual(profile.seq_len, seq_len)
        self.assertTrue(profile.git_commit)

    def test_max_length_allows_nonzero_absolute_position_bases(self):
        accel = AttentionAccelerator()
        accel.configure(512, q_pos_base=31, kv_pos_base=7, causal=True)
        with self.assertRaisesRegex(ValueError, "16-bit range"):
            accel.configure(2, q_pos_base=65535, kv_pos_base=0, causal=True)

    def test_context_manager_releases_buffers(self):
        with AttentionAccelerator() as accel:
            self.assertFalse(accel._closed)
        self.assertTrue(accel._closed)
        with self.assertRaises(RuntimeError):
            accel.run_attention(
                np.zeros((N_Q_HEADS, 1, HEAD_DIM), dtype=np.uint16),
                np.zeros((N_KV_HEADS, 1, HEAD_DIM), dtype=np.uint16),
                np.zeros((N_KV_HEADS, 1, HEAD_DIM), dtype=np.uint16),
                seq_len=1,
            )


if __name__ == "__main__":
    unittest.main()
