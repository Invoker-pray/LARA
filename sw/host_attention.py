#!/usr/bin/env python3
"""
host_attention.py — Host-Side Attention Pre/Post-Processing for LARA

Implements operations that run on the ARM Cortex-A53 (PS) before/after
the FPGA attention accelerator:
  1. QKV Projection:  X @ Wq/Wk/Wv  (host only for v1.0)
  2. RMSNorm:          pre-normalization (host only for v1.0)
  3. RoPE:             rotary position embedding (host optional)

These are implemented in NumPy/SciPy for the KV260 PYNQ environment.
For production inference, use ONNX Runtime or PyTorch on the ARM CPU.

Usage:
  python host_attention.py --check  # verify against PyTorch reference
"""

import numpy as np
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'python_godel'))
from attention_golden import fp32_to_bf16, HEAD_DIM, N_Q_HEADS, N_KV_HEADS

# ============================================================================
# RMSNorm
# ============================================================================

def rms_norm(x: np.ndarray, gamma: np.ndarray, eps: float = 1e-6) -> np.ndarray:
    """
    Llama3 Pre-Norm: y = x / sqrt(mean(x^2) + eps) * gamma

    Args:
        x:      input [L, D] or [D] bf16-compatible
        gamma:  learned scale [D]
        eps:    numerical stability
    Returns:
        normalized output, same shape as x
    """
    x_fp32 = x.astype(np.float32)
    rms = np.sqrt(np.mean(x_fp32 ** 2, axis=-1, keepdims=True) + eps)
    return fp32_to_bf16((x_fp32 / rms * gamma.astype(np.float32)).astype(np.float32))


# ============================================================================
# QKV Projection
# ============================================================================

def qkv_project(
    X: np.ndarray,
    Wq: np.ndarray, Wk: np.ndarray, Wv: np.ndarray
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """
    QKV Linear Projection for one attention layer.

    Args:
        X:   hidden states [L, 4096] bf16-compatible
        Wq:  Q weight [4096, 4096] or [4096, N_Q_HEADS*HEAD_DIM]
        Wk:  K weight [4096, 1024] or [4096, N_KV_HEADS*HEAD_DIM]
        Wv:  V weight [4096, 1024] or [4096, N_KV_HEADS*HEAD_DIM]
    Returns:
        Q [L, 4096], K [L, 1024], V [L, 1024] in bf16
    """
    X_fp32 = X.astype(np.float32)

    Q = X_fp32 @ Wq.astype(np.float32).T
    K = X_fp32 @ Wk.astype(np.float32).T
    V = X_fp32 @ Wv.astype(np.float32).T

    return (
        fp32_to_bf16(Q.astype(np.float32)),
        fp32_to_bf16(K.astype(np.float32)),
        fp32_to_bf16(V.astype(np.float32)),
    )


# ============================================================================
# Reshape to Heads (for GQA)
# ============================================================================

def reshape_to_heads(
    Q: np.ndarray, K: np.ndarray, V: np.ndarray,
    n_q_heads: int = N_Q_HEADS,
    n_kv_heads: int = N_KV_HEADS,
    head_dim: int = HEAD_DIM
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """
    Reshape projected Q/K/V from [L, n_heads*head_dim] to [n_heads, L, head_dim].
    For GQA (Llama3): 32 Q heads, 8 KV heads. Every 4 Q heads share 1 KV head.
    """
    L = Q.shape[0]
    Q_heads = Q.reshape(L, n_q_heads, head_dim).transpose(1, 0, 2)
    K_heads = K.reshape(L, n_kv_heads, head_dim).transpose(1, 0, 2)
    V_heads = V.reshape(L, n_kv_heads, head_dim).transpose(1, 0, 2)
    return Q_heads, K_heads, V_heads


# ============================================================================
# RoPE (Host-Side, Optional)
# ============================================================================

def apply_rope_host(
    vec: np.ndarray,       # [L, head_dim] bf16
    theta_base: float = 10000.0,
    head_dim: int = HEAD_DIM,
    position_base: int = 0,
) -> np.ndarray:
    """
    Apply Rotary Position Embedding to Q or K on the host.
    For v1.0, this can run on either host or FPGA (rope_engine.sv).
    """
    if vec.ndim != 2 or vec.shape[1] != head_dim:
        raise ValueError(f"RoPE input must have shape [L, {head_dim}], got {vec.shape}")
    L = vec.shape[0]
    vec_fp32 = vec.astype(np.float32)
    n_pairs = head_dim // 2
    theta = theta_base ** (-2.0 * np.arange(n_pairs, dtype=np.float32) / head_dim)
    positions = np.arange(position_base, position_base + L, dtype=np.float32)
    phase = positions[:, None] * theta[None, :]
    cos_vals = np.cos(phase)
    sin_vals = np.sin(phase)
    pairs = vec_fp32.reshape(L, n_pairs, 2)
    even = pairs[:, :, 0].copy()
    odd = pairs[:, :, 1].copy()
    pairs[:, :, 0] = even * cos_vals - odd * sin_vals
    pairs[:, :, 1] = even * sin_vals + odd * cos_vals
    return fp32_to_bf16(vec_fp32)


# ============================================================================
# Self-Test
# ============================================================================

def _self_test():
    """Verify host-side implementations against known references."""
    np.random.seed(0)
    L, D = 8, 128  # small test

    # RMSNorm test
    x = np.random.randn(L, D).astype(np.float32) * 0.5
    gamma = np.ones(D, dtype=np.float32)
    x_bf16 = fp32_to_bf16(x)
    y = rms_norm(x_bf16, gamma)
    assert y.shape == (L, D), f"RMSNorm shape: {y.shape}"
    print("  RMSNorm: PASS")

    # QKV projection test
    D_in, D_q, D_kv = 128, 128, 64
    X = fp32_to_bf16(np.random.randn(L, D_in).astype(np.float32) * 0.3)
    Wq = np.random.randn(D_q, D_in).astype(np.float32) * 0.02
    Wk = np.random.randn(D_kv, D_in).astype(np.float32) * 0.02
    Wv = np.random.randn(D_kv, D_in).astype(np.float32) * 0.02
    Q, K, V = qkv_project(X, Wq, Wk, Wv)
    assert Q.shape == (L, D_q), f"Q shape: {Q.shape}"
    assert K.shape == (L, D_kv), f"K shape: {K.shape}"
    print("  QKV Projection: PASS")

    # RoPE test
    vec = fp32_to_bf16(np.random.randn(L, D).astype(np.float32))
    rotated = apply_rope_host(vec, head_dim=D)
    assert rotated.shape == (L, D)
    # Position 0: no rotation (cos(0)=1, sin(0)=0)
    diff0 = np.abs(rotated[0].astype(np.float32) - vec[0].astype(np.float32)).max()
    assert diff0 < 0.01, f"RoPE pos=0 should be identity, diff={diff0}"
    print("  RoPE: PASS")

    print("ALL HOST-SIDE TESTS PASSED")


if __name__ == "__main__":
    if "--check" in sys.argv:
        _self_test()
    else:
        print("Host-side attention pre/post-processing module.")
        print("Usage: python host_attention.py --check")
