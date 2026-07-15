#!/usr/bin/env python3
"""KV260 smoke test for the packaged LARA overlay."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from attn_driver import AttentionAccelerator, HEAD_DIM, N_KV_HEADS, N_Q_HEADS


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a small LARA KV260 DMA/attention smoke test")
    parser.add_argument("--bitstream", required=True, help="path to lara_attention.bit; matching .hwh must be beside it")
    parser.add_argument("--seq-len", type=int, help="sequence length; inferred from --npz when omitted")
    parser.add_argument("--npz", help="optional NPZ containing q_heads, k_heads and v_heads as bf16 uint16 arrays")
    args = parser.parse_args()

    if args.npz:
        tensors = np.load(args.npz)
        q = tensors["q_heads"]
        k = tensors["k_heads"]
        v = tensors["v_heads"]
        if q.ndim != 3 or k.ndim != 3 or v.ndim != 3:
            raise ValueError("NPZ tensors must be rank-3 head-major arrays")
        inferred_len = int(q.shape[1])
        if args.seq_len is None:
            args.seq_len = inferred_len
        if int(args.seq_len) != inferred_len:
            raise ValueError(f"--seq-len={args.seq_len} does not match NPZ length {inferred_len}")
    else:
        args.seq_len = 16 if args.seq_len is None else int(args.seq_len)
        q = np.zeros((N_Q_HEADS, args.seq_len, HEAD_DIM), dtype=np.uint16)
        k = np.zeros((N_KV_HEADS, args.seq_len, HEAD_DIM), dtype=np.uint16)
        v = np.zeros_like(k)

    expected_q = (N_Q_HEADS, int(args.seq_len), HEAD_DIM)
    expected_kv = (N_KV_HEADS, int(args.seq_len), HEAD_DIM)
    if q.shape != expected_q or k.shape != expected_kv or v.shape != expected_kv:
        raise ValueError(f"expected Q={expected_q}, K/V={expected_kv}; got {q.shape}, {k.shape}, {v.shape}")

    accel = AttentionAccelerator(str(Path(args.bitstream).resolve()))
    out = accel.run_attention(q, k, v, seq_len=args.seq_len)
    if not args.npz and np.any(out != 0):
        raise RuntimeError("zero-input smoke test produced a non-zero output")
    print("LARA KV260 smoke test PASS")
    print(f"  sequence length: {args.seq_len}")
    print(f"  perf: {accel.read_perf()}")
    print(f"  output words: {out.size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
