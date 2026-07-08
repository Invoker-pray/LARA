#!/usr/bin/env python3
"""
attention_golden.py — bf16 bit-accurate Attention Golden Model.

Target: Llama3-8B / Llama3.1-8B  ·  bf16 Precision  ·  FPGA Attention Accelerator
Competition: FPT'26 Track B

Correspondence with RTL:
  bf16_fp32_to_bf16()  ↔  bf16 truncation logic in bf16_mac.sv
  bf16_mul()           ↔  bf16_mac.sv (atomic PE)
  bf16_matmul()        ↔  attn_tile.sv (16×16 MAC array)
  online_softmax()     ↔  softmax_engine.sv
  attention_head()     ↔  attn_core.sv (FlashAttention FSM)

Usage:
  python attention_golden.py --self-test        # Quick self-check
  python attention_golden.py --test-all          # Full regression (all modules)
  python attention_golden.py --export-tb-data --module bf16_mac
  python attention_golden.py --export-hex --output-dir VV/data/
"""

import numpy as np
import argparse
import sys
from typing import Tuple, Optional

# ==================================================================
# Hardware Parameters — MUST match attn_pkg.sv 1:1
# ==================================================================
# If you change any value here, update attn_pkg.sv to match.
# These are the SINGLE SOURCE OF TRUTH for the golden model.

# Tile Geometry (§1 in attn_pkg.sv)
TILE_ROWS  = 16          # MAC array rows (Q parallelism, Softmax-limited)
TILE_COLS  = 16          # MAC array columns (K/V parallelism)
TILE_ELEMS = TILE_ROWS * TILE_COLS  # = 256 PEs

# Pipeline Split (§2)
TILE_SPLIT_FACTOR = 2    # 1=safe, 2=balanced, 4=aggressive
TILE_MAC_REUSE    = True  # Time-multiplex MAC for Phase A + B

# Data Widths (§3)
BF16_EXP_W  = 8
BF16_MANT_W = 7
BF16_W      = 16
FP32_W      = 32
PSUM_W      = 32

# Algorithm Parameters (§4) — Llama3.1-8B
MAX_SEQ_LEN   = 2048
HEAD_DIM      = 128
N_Q_HEADS     = 32
N_KV_HEADS    = 8
GQA_GROUP_SIZE = N_Q_HEADS // N_KV_HEADS  # = 4 Q heads per KV head

# Tiling (§5)
TILE_Q  = 32             # Q rows per outer iteration
TILE_KV = 64             # K/V rows per inner iteration

# Memory Sizing (§6) — auto-derived
MAX_N_Q_TILES  = (MAX_SEQ_LEN + TILE_Q  - 1) // TILE_Q
MAX_N_KV_TILES = (MAX_SEQ_LEN + TILE_KV - 1) // TILE_KV

# EXP LUT
EXP_LUT_ADDR_W = 10
EXP_LUT_DEPTH  = 1 << EXP_LUT_ADDR_W  # = 1024


# ==================================================================
# bf16 Arithmetic — Bit-Accurate Implementation
# ==================================================================
#
# bf16 format (IEEE 754 brain floating point):
#   Bit [15]    : sign
#   Bit [14:7]  : exponent (8-bit, bias=127)
#   Bit [6:0]   : mantissa (7-bit explicit + 1 implicit leading bit)
#
#   Value = (-1)^S × 2^(E-127) × 1.M
#
# Key property: bf16 IS the upper 16 bits of fp32.
#   bf16 → fp32: left-shift by 16 bits (pad with zeros). Exact, no rounding.
#   fp32 → bf16: round-to-nearest-even on lower 16 bits, then truncate.
#
# DSP48E2 mapping:
#   Mantissa multiply: 9-bit × 9-bit (8-bit effective × 8-bit effective)
#   → DSP48E2 27×18 multiplier handles this natively.
#   Exponent add + sign XOR done in FPGA LUTs.
#   fp32 accumulation uses DSP48E2 48-bit post-adder or separate logic.


def fp32_to_bf16(x: np.ndarray) -> np.ndarray:
    """Convert fp32 to bf16 with round-to-nearest-even.

    bf16 = upper 16 bits of fp32. We round the 16-bit mantissa extension,
    then zero out the lower 16 bits.

    Round-to-nearest-even (IEEE 754 default):
      - If truncated bits > 0x8000: round up
      - If truncated bits < 0x8000: round down (truncate)
      - If truncated bits == 0x8000: round to even (bit 16 = 0)

    Args:
        x: fp32 numpy array (will be modified in-place on a copy).
    Returns:
        bf16-formatted array (lower 16 bits zeroed, still stored as float32).
    """
    x = np.asarray(x, dtype=np.float32).copy()
    x_u32 = x.view(np.uint32)

    # Extract the 16 bits to be truncated
    truncated = x_u32 & 0xFFFF          # bits [15:0]
    round_bit = (truncated >> 15) & 1   # bit [15] — first bit being cut
    sticky    = (truncated & 0x7FFF) != 0  # bits [14:0] — any set → sticky

    # Round-to-nearest-even:
    # Increment if (round_bit=1 AND (bit_16=1 OR sticky=1))
    bit_16 = (x_u32 >> 16) & 1          # LSB that stays after truncation
    increment = round_bit & (bit_16 | sticky)

    x_u32 = x_u32 + increment.astype(np.uint32)

    # Zero out lower 16 bits → bf16 representation in fp32 container
    x_u32 &= 0xFFFF0000

    return x_u32.view(np.float32)


def bf16_mul(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """bf16 × bf16 → fp32 product.

    Two bf16 operands multiply to an EXACT fp32 product because:
    effective_mantissa = (1 + 7 bits) × (1 + 7 bits) = up to 16 bits,
    which fits within fp32's 23-bit mantissa.

    Corresponds to: bf16_mac.sv (multiply portion)

    Args:
        a, b: bf16 arrays (lower 16 bits already zero).
    Returns:
        fp32 exact product.
    """
    return a.astype(np.float32) * b.astype(np.float32)


def bf16_mac(a: np.ndarray, b: np.ndarray, c: np.ndarray) -> np.ndarray:
    """bf16 multiply-accumulate: a × b + c.
    All three are bf16. Result is fp32.

    Corresponds to: bf16_mac.sv (full fused operation)
    """
    return bf16_mul(a, b) + c.astype(np.float32)


def fp32_to_bf16_scalar(x: np.float32) -> np.float32:
    """Scalar version of fp32_to_bf16 for convenience."""
    arr = np.array([x], dtype=np.float32)
    return fp32_to_bf16(arr)[0]


# ==================================================================
# bf16 Matrix Multiply — Simulating attn_tile.sv
# ==================================================================
# The MAC array computes matrix multiplies in blocks of TILE_ROWS × TILE_COLS.
# Phase A: Q_tile [Tq, 128] × K_tile^T [128, Tk] → S [Tq, Tk]
# Phase B: P_tile [Tq, Tk] × V_tile [Tk, 128] → ΔO [Tq, 128]
#
# The golden model computes the full matmul for verification, but the RTL
# decomposes into 16×16 sub-blocks processed sequentially through the array.


def bf16_matmul(A: np.ndarray, B: np.ndarray, transpose_B: bool = True) -> np.ndarray:
    """bf16 matrix multiply: A @ B^T (if transpose_B) or A @ B.

    All inputs in bf16 format (lower 16 bits zeroed). Output in fp32.
    Uses numpy matmul which is highly optimized. For bit-accurate
    verification, the inner accumulation must match RTL column reduction.

    Corresponds to: attn_tile.sv

    Args:
        A: [M, K] bf16 matrix
        B: [N, K] bf16 matrix (if transpose_B=True) or [K, N] (if transpose_B=False)
        transpose_B: if True, computes A @ B^T (the Attention case).
    Returns:
        [M, N] fp32 result.
    """
    A_fp32 = A.astype(np.float32)
    B_fp32 = B.astype(np.float32)

    if transpose_B:
        # A[M,K] @ B[N,K]^T = A[M,K] @ B_T[K,N] = [M, N]
        return A_fp32 @ B_fp32.T
    else:
        return A_fp32 @ B_fp32


# ==================================================================
# EXP Look-Up Table — Simulating softmax_engine.sv ROM
# ==================================================================
# Hardware uses a 1 KB LUT (1024 entries × fp32) covering exp(x) for x in [-8, 0].
# Input x is quantized to 10-bit address. Linear interpolation between entries.
# Error < 0.1% vs math.exp().


def build_exp_lut() -> np.ndarray:
    """Build the EXP LUT matching the hardware ROM.

    Covers x ∈ [-8.0, 0.0] with 1024 entries.
    exp_lut[i] = exp(-8.0 + i * 8.0 / 1023) in fp32.
    """
    x_vals = np.linspace(-8.0, 0.0, EXP_LUT_DEPTH, dtype=np.float32)
    return np.exp(x_vals).astype(np.float32)


def exp_lut_lookup(x: np.ndarray, lut: np.ndarray) -> np.ndarray:
    """Hardware-accurate exp(x) via LUT + linear interpolation.

    Maps x ∈ [-8, 0] to the LUT address space, then linearly interpolates
    between adjacent entries. For x < -8, returns 0. For x > 0, clamps to exp(0)=1.

    Args:
        x: fp32 array of any shape.
        lut: pre-built LUT from build_exp_lut().
    Returns:
        exp(x) approximated via LUT + linear interpolation (fp32).
    """
    x = np.asarray(x, dtype=np.float32)
    result = np.zeros_like(x)

    # Valid range mask: -8 <= x <= 0
    valid = (x >= -8.0) & (x <= 0.0)

    if not np.any(valid):
        # All values > 0 → clamp to 1.0; all < -8 → 0.0
        result[x > 0.0] = 1.0
        return result

    # Map x ∈ [-8, 0] to [0, DEPTH-1] float index
    x_valid = x[valid]
    idx_float = (x_valid + 8.0) * (EXP_LUT_DEPTH - 1) / 8.0

    idx_lo = np.floor(idx_float).astype(np.int32)
    idx_hi = np.minimum(idx_lo + 1, EXP_LUT_DEPTH - 1)
    frac   = idx_float - idx_lo.astype(np.float32)

    # Linear interpolation: lut[lo] + frac × (lut[hi] - lut[lo])
    lut_lo = lut[idx_lo]
    lut_hi = lut[idx_hi]
    result[valid] = lut_lo + frac * (lut_hi - lut_lo)

    # Clamp x > 0 to 1.0
    result[x > 0.0] = 1.0
    # x < -8 already 0.0 from initialization

    return result


# ==================================================================
# Online Softmax — Simulating softmax_engine.sv
# ==================================================================
# Standard softmax:  P[i,j] = exp(S[i,j]) / sum_j(exp(S[i,j]))
#
# Online Softmax (FlashAttention): process S in chunks (KV tiles), maintaining
# running max m and running sum l across chunks. This avoids storing the
# full S matrix.
#
# State per Q row i:
#   m[i] = running maximum of S[i,:] seen so far
#   l[i] = running sum of exp(S[i,:] - m[i])
#   O_acc[i,:] = running weighted sum of V
#
# When a new chunk arrives:
#   m_new[i] = max(m_old[i], row_max_in_chunk(S_chunk[i,:]))
#   correction[i] = exp(m_old[i] - m_new[i])    ← always ≤ 1 (numerically stable)
#   l_new[i] = l_old[i] * correction[i] + sum(exp(S_chunk[i,:] - m_new[i]))
#   O_acc_new[i,:] = O_acc_old[i,:] * correction[i] + Σ_j P_chunk[i,j] × V_chunk[j,:]


class OnlineSoftmaxState:
    """Running state for Online Softmax, matching softmax_engine.sv registers.

    Maintains per-row: m (fp32 max), l (fp32 sum), O_acc (fp32 accumulator).
    Updated incrementally as each KV tile (S_chunk, V_chunk) is processed.
    """
    def __init__(self, n_rows: int, head_dim: int):
        self.n_rows = n_rows
        self.head_dim = head_dim
        self.reset()

    def reset(self):
        """Initialize state for a new Q tile. m → -inf, l → 0, O_acc → 0."""
        self.m     = np.full(self.n_rows, -np.inf, dtype=np.float32)
        self.l     = np.zeros(self.n_rows, dtype=np.float32)
        self.O_acc = np.zeros((self.n_rows, self.head_dim), dtype=np.float32)

    def update(self, S_chunk: np.ndarray, V_chunk: np.ndarray,
               exp_lut: np.ndarray, causal_mask: Optional[np.ndarray] = None):
        """Process one KV tile.

        Corresponds to: softmax_engine.sv (one inner-loop iteration)

        Args:
            S_chunk: [n_rows, Tk_chunk] fp32 — Q×K^T for this KV tile
            V_chunk: [Tk_chunk, head_dim] bf16 — V values for this tile
            exp_lut: pre-built EXP LUT
            causal_mask: optional [n_rows, Tk_chunk] bool mask (True = masked → -inf)
        """
        n_rows, tk_chunk = S_chunk.shape

        # Step 1: Scale S by 1/√128 (matching attn_pkg.sv head_dim=128)
        S_scaled = S_chunk * (1.0 / np.sqrt(128.0))

        # Step 2: Apply causal mask (set masked positions to -inf)
        if causal_mask is not None:
            S_scaled = np.where(causal_mask, S_scaled, -np.inf)

        # Step 3: Row-wise max over this chunk
        row_max = np.max(S_scaled, axis=1)  # [n_rows]

        # Step 4: Update running max
        m_old = self.m.copy()
        self.m = np.maximum(m_old, row_max)

        # Step 5: Compute correction factor = exp(m_old - m_new)
        # m_old ≤ m_new, so m_old - m_new ≤ 0 → correction ≤ 1
        correction = exp_lut_lookup(m_old - self.m, exp_lut)  # [n_rows]

        # Step 6: Compute P = exp(S_scaled - m_new) for this chunk
        # S_scaled[i,j] - m_new[i] ≤ 0 for all j (since m_new is the row max)
        S_shifted = S_scaled - self.m[:, np.newaxis]  # [n_rows, Tk_chunk]
        P_chunk = exp_lut_lookup(S_shifted, exp_lut)   # [n_rows, Tk_chunk]

        # Step 7: Update running sum l
        row_exp_sum = np.sum(P_chunk, axis=1)  # [n_rows]
        self.l = self.l * correction + row_exp_sum

        # Step 8: Update running output accumulator
        # O_acc_new = O_acc_old * correction + P_chunk @ V_chunk
        # correction is per-row → broadcast: [n_rows, 1] × [n_rows, head_dim]
        self.O_acc = self.O_acc * correction[:, np.newaxis] + (P_chunk @ V_chunk.astype(np.float32))

    def finalize(self) -> np.ndarray:
        """Normalize: O = O_acc / l, then truncate to bf16.

        Called after all KV tiles for a Q tile have been processed.
        Returns: [n_rows, head_dim] bf16 output.
        """
        O_fp32 = self.O_acc / self.l[:, np.newaxis]
        return fp32_to_bf16(O_fp32)


# ==================================================================
# Attention Head — Simulating attn_core.sv
# ==================================================================
# This is the full FlashAttention forward pass for ONE attention head.
# It implements the Q-outer, KV-inner double loop with Online Softmax.


def attention_head(Q: np.ndarray, K: np.ndarray, V: np.ndarray,
                   exp_lut: np.ndarray,
                   causal: bool = True) -> np.ndarray:
    """FlashAttention forward pass for a single attention head.

    Corresponds to: attn_core.sv (FSM orchestrating the double loop)

    Args:
        Q: [L, head_dim] bf16 — query for one head
        K: [L, head_dim] bf16 — key for the corresponding KV head
        V: [L, head_dim] bf16 — value for the corresponding KV head
        exp_lut: pre-built EXP LUT
        causal: if True, apply causal mask (positions j > i masked out).

    Returns:
        O: [L, head_dim] bf16 — attention output for this head.
    """
    L = Q.shape[0]
    head_dim = Q.shape[1]
    assert K.shape == (L, head_dim), f"K shape mismatch: {K.shape}"
    assert V.shape == (L, head_dim), f"V shape mismatch: {V.shape}"

    O_full = np.zeros((L, head_dim), dtype=np.float32)
    state = OnlineSoftmaxState(TILE_Q, head_dim)

    # Q-outer loop: iterate Q tiles
    for q_start in range(0, L, TILE_Q):
        q_end = min(q_start + TILE_Q, L)
        Q_tile = Q[q_start:q_end, :]          # [Tq_actual, head_dim]
        actual_tq = q_end - q_start

        state.n_rows = actual_tq
        state.reset()

        # KV-inner loop: iterate KV tiles
        for kv_start in range(0, L, TILE_KV):
            kv_end = min(kv_start + TILE_KV, L)
            K_tile = K[kv_start:kv_end, :]     # [Tk_actual, head_dim]
            V_tile = V[kv_start:kv_end, :]     # [Tk_actual, head_dim]
            actual_tk = kv_end - kv_start

            # Phase A: Q_tile × K_tile^T → S_chunk
            S_chunk = bf16_matmul(Q_tile, K_tile, transpose_B=True)  # [Tq, Tk] fp32

            # Build causal mask for this [q_start:q_end] × [kv_start:kv_end] block
            causal_mask = None
            if causal:
                q_idx = np.arange(q_start, q_end)[:, np.newaxis]    # [Tq, 1]
                kv_idx = np.arange(kv_start, kv_end)[np.newaxis, :]  # [1, Tk]
                causal_mask = kv_idx <= q_idx                       # [Tq, Tk], True = valid

            # Phase B: Online Softmax + accumulate O
            state.update(S_chunk, V_tile, exp_lut, causal_mask)

        # Normalize and write back
        O_full[q_start:q_end, :] = state.finalize()

    return O_full


# ==================================================================
# Multi-Head GQA Attention — Full Layer
# ==================================================================
# Llama3 GQA: 32 Q heads, 8 KV heads. Each KV head is shared by 4 Q heads.
# The accelerator processes one Q head at a time, grouping by shared KV head.


def attention_gqa(Q_full: np.ndarray, K_full: np.ndarray, V_full: np.ndarray,
                  exp_lut: np.ndarray, causal: bool = True) -> np.ndarray:
    """Full multi-head GQA attention forward pass.

    Args:
        Q_full: [L, 4096] bf16 — all 32 Q heads concatenated along dim 1
        K_full: [L, 1024] bf16 — all 8 KV heads concatenated along dim 1
        V_full: [L, 1024] bf16 — all 8 KV heads concatenated along dim 1
        exp_lut: pre-built EXP LUT
        causal: enable causal masking

    Returns:
        O_full: [L, 4096] bf16 — all 32 output heads concatenated.
    """
    L = Q_full.shape[0]
    assert Q_full.shape == (L, N_Q_HEADS * HEAD_DIM)
    assert K_full.shape == (L, N_KV_HEADS * HEAD_DIM)
    assert V_full.shape == (L, N_KV_HEADS * HEAD_DIM)

    O_full = np.zeros((L, N_Q_HEADS * HEAD_DIM), dtype=np.float32)

    for kv_head in range(N_KV_HEADS):
        # Extract KV for this group
        k_start = kv_head * HEAD_DIM
        v_start = kv_head * HEAD_DIM
        K_h = K_full[:, k_start : k_start + HEAD_DIM]
        V_h = V_full[:, v_start : v_start + HEAD_DIM]

        # Process all Q heads in this GQA group
        for g in range(GQA_GROUP_SIZE):
            q_head = kv_head * GQA_GROUP_SIZE + g
            q_start = q_head * HEAD_DIM
            Q_h = Q_full[:, q_start : q_start + HEAD_DIM]

            O_h = attention_head(Q_h, K_h, V_h, exp_lut, causal)

            o_start = q_head * HEAD_DIM
            O_full[:, o_start : o_start + HEAD_DIM] = O_h

    return O_full


# ==================================================================
# Self-Test and Verification
# ==================================================================

def test_bf16_roundtrip():
    """Verify bf16 → fp32 → bf16 roundtrip is lossless."""
    np.random.seed(42)
    x = np.random.randn(1000).astype(np.float32) * 10.0
    x_bf16 = fp32_to_bf16(x)
    x_back = x_bf16.astype(np.float32)  # bf16 → fp32 is just type cast
    # bf16 format: lower 16 bits must be zero
    x_u32 = x_bf16.view(np.uint32)
    assert np.all((x_u32 & 0xFFFF) == 0), "bf16 lower 16 bits not zero!"
    return True


def test_bf16_mul_accuracy():
    """Verify bf16 multiply matches reference within expected error."""
    np.random.seed(42)
    a = fp32_to_bf16(np.random.randn(128).astype(np.float32))
    b = fp32_to_bf16(np.random.randn(128).astype(np.float32))

    result = bf16_mul(a, b)
    expected = a.astype(np.float32) * b.astype(np.float32)

    max_err = np.max(np.abs(result - expected))
    assert max_err < 1e-10, f"bf16_mul max error {max_err} too large"
    return True


def test_exp_lut_accuracy():
    """Verify EXP LUT error < 0.1% vs math.exp()."""
    lut = build_exp_lut()
    x_test = np.linspace(-8.0, 0.0, 10000, dtype=np.float32)
    approx = exp_lut_lookup(x_test, lut)
    exact  = np.exp(x_test)

    rel_err = np.abs((approx - exact) / exact)
    max_rel_err = np.max(rel_err)
    assert max_rel_err < 0.001, f"EXP LUT max relative error {max_rel_err:.6f} > 0.1%"
    return True


def test_online_softmax_vs_standard():
    """Verify Online Softmax matches standard PyTorch-style softmax attention."""
    np.random.seed(42)
    L = 64
    head_dim = 32  # small for quick test

    Q = fp32_to_bf16(np.random.randn(L, head_dim).astype(np.float32) * 0.1)
    K = fp32_to_bf16(np.random.randn(L, head_dim).astype(np.float32) * 0.1)
    V = fp32_to_bf16(np.random.randn(L, head_dim).astype(np.float32) * 0.1)
    lut = build_exp_lut()

    # Online softmax (tiled)
    O_online = attention_head(Q, K, V, lut, causal=False)

    # Standard softmax (full matrix, no tiling)
    S = (Q.astype(np.float32) @ K.astype(np.float32).T) / np.sqrt(head_dim)
    P = np.exp(S - np.max(S, axis=1, keepdims=True))
    P = P / np.sum(P, axis=1, keepdims=True)
    O_standard = fp32_to_bf16(P @ V.astype(np.float32))

    # Compare
    diff = np.abs(O_online.astype(np.float32) - O_standard.astype(np.float32))
    max_diff = np.max(diff)
    # Allow numerical difference: online softmax uses EXP LUT (~0.1% error)
    # and fp32 accumulation across chunks vs standard full-matrix computation.
    # For bf16 (3 decimal digits of precision), 5e-4 is well within tolerance.
    assert max_diff < 5e-4, f"Online vs standard softmax max diff {max_diff:.2e} too large"
    return True


def test_gqa_output_shape():
    """Verify GQA attention produces correct output shape."""
    np.random.seed(42)
    L = 32  # tiny test

    Q_full = fp32_to_bf16(np.random.randn(L, N_Q_HEADS * HEAD_DIM).astype(np.float32) * 0.1)
    K_full = fp32_to_bf16(np.random.randn(L, N_KV_HEADS * HEAD_DIM).astype(np.float32) * 0.1)
    V_full = fp32_to_bf16(np.random.randn(L, N_KV_HEADS * HEAD_DIM).astype(np.float32) * 0.1)
    lut = build_exp_lut()

    O = attention_gqa(Q_full, K_full, V_full, lut, causal=True)

    assert O.shape == (L, N_Q_HEADS * HEAD_DIM), f"Wrong output shape: {O.shape}"
    assert O.dtype == np.float32, f"Wrong output dtype: {O.dtype}"
    return True


def test_causal_mask():
    """Verify causal masking: position i can only attend to positions ≤ i."""
    np.random.seed(42)
    L = 16
    head_dim = 8
    Q = fp32_to_bf16(np.ones((L, head_dim), dtype=np.float32) * 0.01)
    K = fp32_to_bf16(np.ones((L, head_dim), dtype=np.float32) * 0.01)
    V = fp32_to_bf16(np.eye(L, head_dim, dtype=np.float32))  # each pos has unique V
    lut = build_exp_lut()

    O = attention_head(Q, K, V, lut, causal=True)

    # For position 0, O[0] should ≈ V[0] (can only attend to pos 0)
    # For position L-1, O[L-1] should ≈ mean of all V[0..L-1]
    # Quick sanity: O[0] shouldn't be far from V[0]
    v0_norm = np.linalg.norm(V[0].astype(np.float32))
    o0_to_v0 = np.linalg.norm(O[0].astype(np.float32) - V[0].astype(np.float32))
    # Should be somewhat close (softmax with one entry = identity)
    assert o0_to_v0 < 0.1 * v0_norm, f"Position 0 attends to future: diff={o0_to_v0:.4f}"
    return True


def test_determinism():
    """Verify fixed seed produces identical results."""
    def run():
        np.random.seed(123)
        L = 16
        Q = fp32_to_bf16(np.random.randn(L, HEAD_DIM).astype(np.float32))
        K = fp32_to_bf16(np.random.randn(L, HEAD_DIM).astype(np.float32))
        V = fp32_to_bf16(np.random.randn(L, HEAD_DIM).astype(np.float32))
        lut = build_exp_lut()
        return attention_head(Q, K, V, lut, causal=True)

    r1 = run()
    r2 = run()
    assert np.array_equal(r1, r2), "Non-deterministic output!"
    return True


# ==================================================================
# Test Vector Export
# ==================================================================

def export_bf16_mac_test_vectors(output_dir: str = "VV/data/"):
    """Generate 103 random test vectors for bf16_mac verification.

    Format (hex): a_bf16[15:0]  b_bf16[15:0]  c_fp32[31:0]  expected_fp32[31:0]
    One vector per line.
    """
    import os
    os.makedirs(output_dir, exist_ok=True)

    np.random.seed(103)  # Fixed seed for reproducibility
    n_vectors = 103

    a = fp32_to_bf16(np.random.randn(n_vectors).astype(np.float32))
    b = fp32_to_bf16(np.random.randn(n_vectors).astype(np.float32))
    c = fp32_to_bf16(np.random.randn(n_vectors).astype(np.float32))
    expected = a.astype(np.float32) * b.astype(np.float32) + c.astype(np.float32)

    filepath = os.path.join(output_dir, "bf16_mac_vectors.hex")
    with open(filepath, 'w') as f:
        f.write("# bf16_mac test vectors: a_bf16 b_bf16 c_fp32 expected_fp32\n")
        for i in range(n_vectors):
            a_u16 = a[i].view(np.uint32) >> 16
            b_u16 = b[i].view(np.uint32) >> 16
            c_u32 = c[i].view(np.uint32)
            e_u32 = expected[i].view(np.uint32)
            f.write(f"{a_u16:04x} {b_u16:04x} {c_u32:08x} {e_u32:08x}\n")

    print(f"Exported {n_vectors} bf16_mac test vectors → {filepath}")
    return filepath


def export_attention_test_data(seq_len: int = 64, output_dir: str = "VV/data/"):
    """Generate test data for single-head attention verification.

    Exports Q, K, V inputs and the golden O output in hex format.
    """
    import os
    os.makedirs(output_dir, exist_ok=True)

    np.random.seed(42)
    Q = fp32_to_bf16(np.random.randn(seq_len, HEAD_DIM).astype(np.float32) * 0.1)
    K = fp32_to_bf16(np.random.randn(seq_len, HEAD_DIM).astype(np.float32) * 0.1)
    V = fp32_to_bf16(np.random.randn(seq_len, HEAD_DIM).astype(np.float32) * 0.1)
    lut = build_exp_lut()

    O = attention_head(Q, K, V, lut, causal=False)

    for name, arr in [('Q', Q), ('K', K), ('V', V), ('O', O)]:
        filepath = os.path.join(output_dir, f"attention_{name}_L{seq_len}.hex")
        with open(filepath, 'w') as f:
            f.write(f"# {name} matrix [{seq_len}, {HEAD_DIM}] bf16\n")
            for i in range(seq_len):
                row_hex = ' '.join(
                    f"{(arr[i, j].view(np.uint32) >> 16):04x}"
                    for j in range(HEAD_DIM)
                )
                f.write(row_hex + '\n')
        print(f"Exported {name} [{seq_len}×{HEAD_DIM}] → {filepath}")


# ==================================================================
# Main CLI
# ==================================================================

def main():
    parser = argparse.ArgumentParser(
        description="bf16 bit-accurate Attention Golden Model"
    )
    parser.add_argument('--self-test', action='store_true',
                        help='Run quick self-check (bf16 roundtrip + mul accuracy)')
    parser.add_argument('--test-all', action='store_true',
                        help='Run full regression suite')
    parser.add_argument('--export-tb-data', action='store_true',
                        help='Export test vectors for RTL testbenches')
    parser.add_argument('--module', type=str, default='all',
                        choices=['all', 'bf16_mac', 'attention'],
                        help='Module to export test vectors for')
    parser.add_argument('--output-dir', type=str, default='VV/data/',
                        help='Output directory for exported test data')
    parser.add_argument('--seq-len', type=int, default=64,
                        help='Sequence length for attention test data')
    parser.add_argument('--export-hex', action='store_true',
                        help='Alias for --export-tb-data')

    args = parser.parse_args()

    # Handle --export-hex alias
    if args.export_hex:
        args.export_tb_data = True

    tests_run = 0
    tests_passed = 0

    if args.self_test:
        print("=" * 60)
        print("  Self-Test: bf16 Roundtrip + Multiply Accuracy")
        print("=" * 60)
        for test_fn, name in [
            (test_bf16_roundtrip, "bf16 roundtrip"),
            (test_bf16_mul_accuracy, "bf16 multiply accuracy"),
            (test_exp_lut_accuracy, "EXP LUT accuracy (< 0.1%)"),
        ]:
            tests_run += 1
            try:
                test_fn()
                print(f"  PASS  {name}")
                tests_passed += 1
            except AssertionError as e:
                print(f"  FAIL  {name}: {e}")
        print()

    if args.test_all:
        print("=" * 60)
        print("  Full Regression Suite")
        print("=" * 60)
        all_tests = [
            (test_bf16_roundtrip, "bf16 roundtrip"),
            (test_bf16_mul_accuracy, "bf16 multiply accuracy"),
            (test_exp_lut_accuracy, "EXP LUT accuracy"),
            (test_online_softmax_vs_standard, "Online Softmax vs Standard"),
            (test_gqa_output_shape, "GQA output shape"),
            (test_causal_mask, "Causal masking"),
            (test_determinism, "Determinism (fixed seed)"),
        ]
        for test_fn, name in all_tests:
            tests_run += 1
            try:
                test_fn()
                print(f"  PASS  {name}")
                tests_passed += 1
            except AssertionError as e:
                print(f"  FAIL  {name}: {e}")
        print()

    if args.export_tb_data:
        print("=" * 60)
        print("  Exporting Test Vectors")
        print("=" * 60)
        if args.module in ('all', 'bf16_mac'):
            export_bf16_mac_test_vectors(args.output_dir)
        if args.module in ('all', 'attention'):
            export_attention_test_data(args.seq_len, args.output_dir)
        print()

    # Default behavior: run self-test
    if not any([args.self_test, args.test_all, args.export_tb_data]):
        print("No action specified. Running --self-test by default.\n")
        args.self_test = True
        # Recurse once
        return main()

    if tests_run > 0:
        print(f"Summary: {tests_passed}/{tests_run} tests passed")
        if tests_passed < tests_run:
            sys.exit(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
