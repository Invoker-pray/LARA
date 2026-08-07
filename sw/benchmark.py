#!/usr/bin/env python3
"""Report the deployed LARA contract and an explicitly scoped cycle model.

This is not an on-board benchmark.  It reports analytical tile counts and the
synthesis-path softmax latency measured by ``tb_softmax``.  End-to-end latency,
throughput, and GOPS are intentionally omitted until cycle-profile or board
measurements covering MAC, output-buffer, and DMA phases are supplied.
"""

from __future__ import annotations

import argparse
import json

# 76.922310 MHz missed post-route setup timing; retain it for rollback evidence.
# FREQ_MHZ = 76.922310
FREQ_MHZ = 71.427856
DSP_COUNT = 165
MAX_SEQ_LEN = 512
HEAD_DIM = 128
N_Q_HEADS = 32
N_KV_HEADS = 8
TILE_Q = 32
TILE_KV = 64
TILE_ROWS = 16
TILE_COLS = 16
SOFTMAX_CYCLES_P0_BASELINE = 1106
SOFTMAX_CYCLES_PER_SUBBLOCK = 626


def ceil_div(value: int, divisor: int) -> int:
    """Return ceil(value / divisor) for positive integers."""
    return (value + divisor - 1) // divisor


def tile_pairs_per_head(
    seq_len: int,
    causal: bool,
    q_pos_base: int = 0,
    kv_pos_base: int = 0,
) -> int:
    """Match attn_core's Q-tile/KV-tile traversal analytically."""
    n_q_tiles = ceil_div(seq_len, TILE_Q)
    n_kv_tiles = ceil_div(seq_len, TILE_KV)
    if not causal:
        return n_q_tiles * n_kv_tiles

    pairs = 0
    for q_tile in range(n_q_tiles):
        active_rows = min(TILE_Q, seq_len - q_tile * TILE_Q)
        q_end = q_pos_base + q_tile * TILE_Q + active_rows - 1
        if q_end < kv_pos_base:
            last_kv_tile = 0
        else:
            last_kv_tile = min((q_end - kv_pos_base) // TILE_KV, n_kv_tiles - 1)
        pairs += last_kv_tile + 1
    return pairs


def compute_model(
    seq_len: int = MAX_SEQ_LEN,
    causal: bool = True,
    q_pos_base: int = 0,
    kv_pos_base: int = 0,
) -> dict[str, object]:
    """Build a scoped, reproducible analytical model for the current RTL."""
    if not 1 <= seq_len <= MAX_SEQ_LEN:
        raise ValueError(f"seq_len must be in 1..{MAX_SEQ_LEN}, got {seq_len}")
    if q_pos_base + seq_len > MAX_SEQ_LEN:
        raise ValueError("q_pos_base + seq_len exceeds the deployed contract")
    if kv_pos_base + seq_len > MAX_SEQ_LEN:
        raise ValueError("kv_pos_base + seq_len exceeds the deployed contract")

    per_head_pairs = tile_pairs_per_head(
        seq_len, causal, q_pos_base, kv_pos_base
    )
    transaction_pairs = per_head_pairs * N_Q_HEADS
    q_microtiles = ceil_div(min(seq_len, TILE_Q), TILE_ROWS)
    # Each core KV tile contains up to four 16-column softmax subblocks.
    full_kv_subblocks = ceil_div(min(seq_len, TILE_KV), TILE_COLS)
    softmax_subblocks_upper_bound = (
        transaction_pairs * q_microtiles * full_kv_subblocks
    )
    softmax_cycles_upper_bound = (
        softmax_subblocks_upper_bound * SOFTMAX_CYCLES_PER_SUBBLOCK
    )

    return {
        "contract": {
            "frequency_mhz": FREQ_MHZ,
            "dsp_count_post_route": DSP_COUNT,
            "max_seq_len": MAX_SEQ_LEN,
            "head_dim": HEAD_DIM,
            "q_heads": N_Q_HEADS,
            "kv_heads": N_KV_HEADS,
            "gqa_group_size": N_Q_HEADS // N_KV_HEADS,
            "tile_q": TILE_Q,
            "tile_kv": TILE_KV,
            "physical_mac_rows": TILE_ROWS,
            "physical_mac_cols": TILE_COLS,
        },
        "workload": {
            "seq_len": seq_len,
            "causal": causal,
            "q_pos_base": q_pos_base,
            "kv_pos_base": kv_pos_base,
        },
        "analytical": {
            "tile_pairs_per_q_head": per_head_pairs,
            "tile_pairs_full_32_head_transaction": transaction_pairs,
            "softmax_subblocks_upper_bound": softmax_subblocks_upper_bound,
            "softmax_cycles_per_16x16_subblock": SOFTMAX_CYCLES_PER_SUBBLOCK,
            "softmax_cycles_p0_baseline": SOFTMAX_CYCLES_P0_BASELINE,
            "softmax_cycle_reduction_vs_p0": (
                SOFTMAX_CYCLES_P0_BASELINE - SOFTMAX_CYCLES_PER_SUBBLOCK
            ),
            "softmax_cycle_reduction_percent_vs_p0": round(
                100.0
                * (SOFTMAX_CYCLES_P0_BASELINE - SOFTMAX_CYCLES_PER_SUBBLOCK)
                / SOFTMAX_CYCLES_P0_BASELINE,
                3,
            ),
            "softmax_cycles_upper_bound": softmax_cycles_upper_bound,
        },
        "measurement_scope": {
            "softmax_cycles_source": "VCS synthesis-path tb_softmax",
            "includes_mac": False,
            "includes_output_buffer": False,
            "includes_dma_or_memory_wait": False,
            "end_to_end_latency_reported": False,
            "throughput_reported": False,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seq-len", type=int, default=MAX_SEQ_LEN)
    parser.add_argument("--non-causal", action="store_true")
    parser.add_argument("--q-pos-base", type=int, default=0)
    parser.add_argument("--kv-pos-base", type=int, default=0)
    args = parser.parse_args()
    result = compute_model(
        seq_len=args.seq_len,
        causal=not args.non_causal,
        q_pos_base=args.q_pos_base,
        kv_pos_base=args.kv_pos_base,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
