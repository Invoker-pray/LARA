#!/usr/bin/env python3
"""Generate exact-bf16 NPZ cases for the KV260 P5 board matrix."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import time
import zipfile
from pathlib import Path

import numpy as np

# Support both `python3 sw/generate_board_cases.py` and module execution.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from python_godel.attention_golden import (
    HEAD_DIM,
    N_KV_HEADS,
    N_Q_HEADS,
    attention_gqa,
    build_exp_lut,
    fp32_to_bf16,
)
from python_godel.attention_rtl_golden import (
    attention_gqa_rtl,
    attention_gqa_rtl_vectorized,
)

MAX_SEQ_LEN = 512
MAX_ABSOLUTE_POSITION = 1 << 16


def _resolve_position_bases(
    seq_len: int,
    q_pos_base: int,
    kv_pos_base: int,
) -> tuple[int, int]:
    """Validate absolute position bases without silently changing them."""
    if seq_len < 1 or seq_len > MAX_SEQ_LEN:
        raise ValueError(f"sequence length must be in 1..{MAX_SEQ_LEN}, got {seq_len}")
    for name, value in (("q_pos_base", q_pos_base), ("kv_pos_base", kv_pos_base)):
        if value < 0 or value >= MAX_ABSOLUTE_POSITION:
            raise ValueError(
                f"{name} must be in 0..{MAX_ABSOLUTE_POSITION - 1}, got {value}"
            )
        if value + seq_len > MAX_ABSOLUTE_POSITION:
            raise ValueError(
                f"{name}+seq_len must be <= {MAX_ABSOLUTE_POSITION}; "
                f"got {value}+{seq_len}"
            )
    return q_pos_base, kv_pos_base


def _to_raw_words(values: np.ndarray) -> np.ndarray:
    """Convert the golden model's bf16-in-fp32 representation to uint16 words."""
    array = np.asarray(values)
    if array.dtype == np.uint16:
        # RTL-contract models already return raw BF16 words.  Reinterpreting
        # those words as float32 values corrupts both inputs and expected data.
        return array.astype(np.uint16, copy=False)
    return (np.asarray(array, dtype=np.float32).view(np.uint32) >> 16).astype(np.uint16)


def _make_case(
    *,
    seq_len: int,
    causal: bool,
    q_pos_base: int,
    kv_pos_base: int,
    seed: int,
    output_dir: Path,
    model: str = "rtl",
    backend: str = "vectorized",
    resume: bool = False,
) -> Path:
    tag = f"L{seq_len}_q{q_pos_base}_kv{kv_pos_base}_{'causal' if causal else 'noncausal'}"
    path = output_dir / f"case_{tag}.npz"
    if resume and path.is_file() and _case_matches(
        path,
        seq_len=seq_len,
        causal=causal,
        q_pos_base=q_pos_base,
        kv_pos_base=kv_pos_base,
        seed=seed,
    ):
        print(f"skip existing complete case: {path.name}", flush=True)
        return path

    rng = np.random.default_rng(seed)
    q_token = fp32_to_bf16(
        rng.normal(0.0, 0.1, (seq_len, N_Q_HEADS * HEAD_DIM)).astype(np.float32)
    )
    k_token = fp32_to_bf16(
        rng.normal(0.0, 0.1, (seq_len, N_KV_HEADS * HEAD_DIM)).astype(np.float32)
    )
    v_token = fp32_to_bf16(
        rng.normal(0.0, 0.1, (seq_len, N_KV_HEADS * HEAD_DIM)).astype(np.float32)
    )
    q_heads = q_token.reshape(seq_len, N_Q_HEADS, HEAD_DIM).transpose(1, 0, 2)
    k_heads = k_token.reshape(seq_len, N_KV_HEADS, HEAD_DIM).transpose(1, 0, 2)
    v_heads = v_token.reshape(seq_len, N_KV_HEADS, HEAD_DIM).transpose(1, 0, 2)
    if model == "rtl":
        rtl_args = dict(
            q_heads=_to_raw_words(q_heads),
            k_heads=_to_raw_words(k_heads),
            v_heads=_to_raw_words(v_heads),
            causal=causal,
            q_pos_base=q_pos_base,
            kv_pos_base=kv_pos_base,
            exp_lut_path=Path(__file__).resolve().parents[1] / "VV/data/exp_lut.hex",
            recip_lut_path=Path(__file__).resolve().parents[1] / "VV/data/recip_lut.hex",
        )
        expected_o = (
            attention_gqa_rtl(**rtl_args)
            if backend == "scalar"
            else attention_gqa_rtl_vectorized(**rtl_args)
        )
    elif model == "python":
        output_token = attention_gqa(
            q_token,
            k_token,
            v_token,
            build_exp_lut(),
            causal=causal,
            q_pos_base=q_pos_base,
            kv_pos_base=kv_pos_base,
        )
        expected_o = output_token.reshape(seq_len, N_Q_HEADS, HEAD_DIM).transpose(1, 0, 2)
    else:
        raise ValueError(f"unsupported board-case model: {model}")

    payload = dict(
        q_heads=_to_raw_words(q_heads),
        k_heads=_to_raw_words(k_heads),
        v_heads=_to_raw_words(v_heads),
        expected_o=_to_raw_words(expected_o),
        seq_len=np.uint16(seq_len),
        causal=np.uint8(causal),
        q_pos_base=np.uint16(q_pos_base),
        kv_pos_base=np.uint16(kv_pos_base),
        seed=np.uint32(seed),
    )
    # Write to a temporary file and replace only after the compressed archive
    # is complete. An interrupted L512 generation cannot leave a valid-looking
    # but truncated NPZ behind.
    tmp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=output_dir,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as stream:
            tmp_path = Path(stream.name)
            np.savez_compressed(stream, **payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp_path, path)
    except BaseException:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)
        raise
    return path


def _case_matches(
    path: Path,
    *,
    seq_len: int,
    causal: bool,
    q_pos_base: int,
    kv_pos_base: int,
    seed: int,
) -> bool:
    """Return true only for a complete case with matching generation metadata."""
    try:
        with np.load(path) as data:
            required = ("q_heads", "k_heads", "v_heads", "expected_o")
            if any(name not in data for name in required):
                return False
            q = np.asarray(data["q_heads"])
            k = np.asarray(data["k_heads"])
            v = np.asarray(data["v_heads"])
            expected = np.asarray(data["expected_o"])
            return (
                q.shape == (N_Q_HEADS, seq_len, HEAD_DIM)
                and k.shape == (N_KV_HEADS, seq_len, HEAD_DIM)
                and v.shape == (N_KV_HEADS, seq_len, HEAD_DIM)
                and expected.shape == (N_Q_HEADS, seq_len, HEAD_DIM)
                and q.dtype == np.uint16
                and k.dtype == np.uint16
                and v.dtype == np.uint16
                and expected.dtype == np.uint16
                and int(np.asarray(data["seq_len"]).item()) == seq_len
                and bool(np.asarray(data["causal"]).item()) == causal
                and int(np.asarray(data["q_pos_base"]).item()) == q_pos_base
                and int(np.asarray(data["kv_pos_base"]).item()) == kv_pos_base
                and int(np.asarray(data["seed"]).item()) == seed
            )
    except (OSError, KeyError, ValueError, zipfile.BadZipFile):
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default="board_cases_v2.6")
    parser.add_argument("--lengths", nargs="+", type=int, default=[1, 16, 32, 64, 128, 512])
    parser.add_argument("--include-noncausal", action="store_true")
    parser.add_argument(
        "--model",
        choices=("rtl", "python"),
        default="rtl",
        help="expected-output contract; rtl matches the deployed synthesis datapath",
    )
    parser.add_argument(
        "--backend",
        choices=("auto", "vectorized", "scalar"),
        default="auto",
        help=(
            "RTL backend; auto/vectorized preserves RTL ordering with fast "
            "NumPy loops, scalar is the slow reference fallback"
        ),
    )
    parser.add_argument("--q-pos-base", type=int, default=0)
    parser.add_argument("--kv-pos-base", type=int, default=0)
    parser.add_argument("--seed", type=int, default=2602)
    parser.add_argument(
        "--resume",
        action="store_true",
        help="skip complete cases whose metadata and shapes match; safe after interruption",
    )
    args = parser.parse_args()
    backend = "vectorized" if args.backend == "auto" else args.backend
    if args.model != "rtl" and args.backend == "scalar":
        raise ValueError("--backend=scalar is only valid with --model=rtl")
    print(f"case generation backend: {backend}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    cases: list[Path] = []
    total_cases = len(args.lengths) * (2 if args.include_noncausal else 1)
    completed_cases = 0
    generation_started = time.monotonic()
    try:
        for index, seq_len in enumerate(args.lengths):
            q_pos_base, kv_pos_base = _resolve_position_bases(
                seq_len, args.q_pos_base, args.kv_pos_base
            )
            modes = (True, False) if args.include_noncausal else (True,)
            for causal in modes:
                mode = "causal" if causal else "noncausal"
                case_started = time.monotonic()
                print(
                    f"[{completed_cases + 1}/{total_cases}] "
                    f"generating L={seq_len} q={q_pos_base} kv={kv_pos_base} {mode}",
                    flush=True,
                )
                cases.append(_make_case(
                    seq_len=seq_len,
                    causal=causal,
                    q_pos_base=q_pos_base,
                    kv_pos_base=kv_pos_base,
                    seed=args.seed + index * 2 + (0 if causal else 1),
                    output_dir=output_dir,
                    model=args.model,
                    backend=backend,
                    resume=args.resume,
                ))
                completed_cases += 1
                case_elapsed = time.monotonic() - case_started
                total_elapsed = time.monotonic() - generation_started
                print(
                    f"[{completed_cases}/{total_cases}] completed "
                    f"L={seq_len} {mode} "
                    f"(case {case_elapsed:.1f}s, total {total_elapsed:.1f}s)",
                    flush=True,
                )
    except KeyboardInterrupt:
        print(
            f"\ncase generation interrupted after {completed_cases}/{total_cases} cases; "
            "completed NPZ files are intact. Rerun with --resume to continue.",
            file=sys.stderr,
            flush=True,
        )
        return 130

    print(
        f"generated {len(cases)} board cases in {output_dir.resolve()} "
        f"(total {time.monotonic() - generation_started:.1f}s)"
    )
    for case in cases:
        print(case.name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
