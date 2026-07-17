#!/usr/bin/env python3
"""Run a deterministic golden-model matrix for the deployed attention contract."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np

from attention_golden import (
    HEAD_DIM,
    N_KV_HEADS,
    N_Q_HEADS,
    attention_gqa,
    build_exp_lut,
    fp32_to_bf16,
)


def run_case(seq_len: int, causal: bool, seed: int) -> dict[str, object]:
    rng = np.random.default_rng(seed)
    q = fp32_to_bf16(
        rng.normal(0.0, 0.1, (seq_len, N_Q_HEADS * HEAD_DIM)).astype(np.float32)
    )
    k = fp32_to_bf16(
        rng.normal(0.0, 0.1, (seq_len, N_KV_HEADS * HEAD_DIM)).astype(np.float32)
    )
    v = fp32_to_bf16(
        rng.normal(0.0, 0.1, (seq_len, N_KV_HEADS * HEAD_DIM)).astype(np.float32)
    )
    start = time.perf_counter()
    output = attention_gqa(q, k, v, build_exp_lut(), causal=causal)
    elapsed_s = time.perf_counter() - start
    return {
        "seq_len": seq_len,
        "causal": causal,
        "seed": seed,
        "q_shape": list(q.shape),
        "k_shape": list(k.shape),
        "o_shape": list(output.shape),
        "finite": bool(np.isfinite(output).all()),
        "max_abs": float(np.max(np.abs(output))) if output.size else 0.0,
        "checksum": float(np.sum(output, dtype=np.float64)),
        "elapsed_s": elapsed_s,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="optional JSON output path")
    parser.add_argument(
        "--lengths", nargs="+", type=int, default=[16, 32, 64, 128, 256, 512]
    )
    args = parser.parse_args()
    cases = []
    for index, seq_len in enumerate(args.lengths):
        if not 1 <= seq_len <= 512:
            raise ValueError(f"sequence length must be in 1..512, got {seq_len}")
        cases.append(run_case(seq_len, True, 1000 + index * 2))
        cases.append(run_case(seq_len, False, 1001 + index * 2))
    result = {
        "contract": {
            "max_seq_len": 512,
            "head_dim": HEAD_DIM,
            "q_heads": N_Q_HEADS,
            "kv_heads": N_KV_HEADS,
            "gqa_group_size": N_Q_HEADS // N_KV_HEADS,
        },
        "cases": cases,
    }
    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(payload + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
