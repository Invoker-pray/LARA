"""RTL-contract golden model for the deployed KV260 attention datapath."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from python_godel.attention_golden import (
    GQA_GROUP_SIZE,
    HEAD_DIM,
    MAX_SEQ_LEN,
    N_KV_HEADS,
    N_Q_HEADS,
    TILE_KV,
    TILE_Q,
)

FP32_MASK = 0xFFFFFFFF
FP32_ZERO = 0x00000000
FP32_NEG_INF = 0xFF800000
FP32_ONE = 0x3F800000
INV_SQRT_D = 0x3DB504F3


def _f32(bits: int) -> np.float32:
    return np.array([bits & FP32_MASK], dtype=np.uint32).view(np.float32)[0]


def _bits(value: np.float32) -> int:
    return int(np.asarray(value, dtype=np.float32).view(np.uint32)) & FP32_MASK


def fp32_add_bits(a: int, b: int) -> int:
    return _bits(np.float32(_f32(a) + _f32(b)))


def fp32_mul_bits(a: int, b: int) -> int:
    return _bits(np.float32(_f32(a) * _f32(b)))


def fp32_sub_bits(a: int, b: int) -> int:
    return fp32_add_bits(a, b ^ 0x80000000)


def fp32_to_bf16_bits(a: int) -> int:
    upper = (a >> 16) & 0xFFFF
    round_up = ((a >> 15) & 1) and (((a >> 0) & 0x7FFF) != 0 or (upper & 1))
    return (upper + int(bool(round_up))) & 0xFFFF


def _fp32_to_q8_23(a: int) -> int:
    if (a & 0x7FFFFFFF) == 0:
        return 0
    sign = (a >> 31) & 1
    exponent = (a >> 23) & 0xFF
    mantissa = (1 << 23) | (a & 0x7FFFFF)
    shift = exponent - 127
    scaled = mantissa << shift if shift >= 0 else mantissa >> (-shift)
    return -scaled if sign else scaled


def _q26_to_fp32(value: int) -> int:
    if value <= 0:
        return FP32_ZERO
    bit_idx = value.bit_length() - 1
    residual = value - (1 << bit_idx)
    if bit_idx < 23:
        mantissa = residual << (23 - bit_idx)
    else:
        mantissa = residual >> (bit_idx - 23)
    exponent = 127 + bit_idx - 26
    return ((exponent & 0xFF) << 23) | (mantissa & 0x7FFFFF)


def load_exp_lut(path: Path) -> list[int]:
    return [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]


def exp_lookup_bits(x: int, lut: list[int]) -> int:
    x_value = _f32(x)
    if x_value < np.float32(-8.0):
        return FP32_ZERO
    if x_value > np.float32(0.0):
        return FP32_ONE
    x_q = _fp32_to_q8_23(x)
    idx_num_signed = x_q + (8 << 23)
    idx_num_signed = max(0, min(1 << 26, idx_num_signed))
    idx_num = idx_num_signed * 1023
    idx = idx_num >> 26
    rem = idx_num - (idx << 26)
    if idx >= 1023:
        return lut[1023]
    frac_fp = _q26_to_fp32(rem)
    delta = fp32_sub_bits(lut[idx + 1], lut[idx])
    return fp32_add_bits(lut[idx], fp32_mul_bits(delta, frac_fp))


def load_recip_lut(path: Path) -> list[int]:
    return [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]


def recip_lut_bits(value: int, lut: list[int]) -> int:
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF
    if fraction == 0:
        return (((254 - exponent) & 0xFF) << 23)
    return (((253 - exponent) & 0xFF) << 23) | lut[fraction >> 15]


def _bf16_product_bits(a: int, b: int) -> int:
    return fp32_mul_bits((int(a) & 0xFFFF) << 16, (int(b) & 0xFFFF) << 16)


def _score_block(q_block: np.ndarray, k_block: np.ndarray) -> np.ndarray:
    rows, cols = q_block.shape[0], k_block.shape[0]
    result = np.zeros((rows, cols), dtype=np.uint32)
    for row in range(rows):
        for col in range(cols):
            acc = FP32_ZERO
            for dim in range(HEAD_DIM):
                acc = fp32_add_bits(
                    acc,
                    _bf16_product_bits(q_block[row, dim], k_block[col, dim]),
                )
            result[row, col] = acc
    return result


def _update_online(
    m_state: list[int],
    l_state: list[int],
    o_acc: np.ndarray,
    scores: np.ndarray,
    v_block: np.ndarray,
    *,
    q_abs_start: int,
    kv_abs_start: int,
    causal: bool,
    kv_tile_first: bool,
    exp_lut: list[int],
) -> None:
    rows, cols = scores.shape
    shifted = np.zeros((rows, cols), dtype=np.uint32)
    p_bf16 = np.zeros((rows, cols), dtype=np.uint16)
    for row in range(rows):
        row_max = FP32_NEG_INF
        valid = [False] * cols
        for col in range(cols):
            valid[col] = (
                (not causal)
                or (q_abs_start + row >= kv_abs_start + col)
            )
            value = int(scores[row, col])
            if not valid[col]:
                value = FP32_NEG_INF
            value = fp32_mul_bits(value, INV_SQRT_D)
            shifted[row, col] = value
            if valid[col] and (
                row_max == FP32_NEG_INF
                or _f32(value) > _f32(row_max)
            ):
                row_max = value
        old_m = m_state[row]
        new_m = row_max if kv_tile_first else (
            old_m if _f32(old_m) >= _f32(row_max) else row_max
        )
        correction = FP32_ZERO if kv_tile_first else exp_lookup_bits(
            fp32_sub_bits(old_m, new_m), exp_lut
        )
        row_sum = FP32_ZERO
        for col in range(cols):
            if valid[col]:
                shifted_value = fp32_sub_bits(shifted[row, col], new_m)
                p_value = exp_lookup_bits(shifted_value, exp_lut)
            else:
                p_value = FP32_ZERO
            shifted[row, col] = p_value
            p_bf16[row, col] = (p_value >> 16) & 0xFFFF
            row_sum = fp32_add_bits(row_sum, p_value)
        if kv_tile_first:
            new_l = row_sum
        else:
            new_l = fp32_add_bits(fp32_mul_bits(l_state[row], correction), row_sum)
        for dim in range(HEAD_DIM):
            delta = FP32_ZERO
            for col in range(cols):
                delta = fp32_add_bits(
                    delta,
                    _bf16_product_bits(p_bf16[row, col], v_block[col, dim]),
                )
            o_acc[row, dim] = fp32_add_bits(
                fp32_mul_bits(int(o_acc[row, dim]), correction),
                delta,
            )
        m_state[row] = new_m
        l_state[row] = new_l


def _bf16_to_fp32_array(values: np.ndarray) -> np.ndarray:
    bits = np.asarray(values, dtype=np.uint32) << 16
    return bits.view(np.float32)


def _fp32_add_array(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    result = np.add(
        np.asarray(a, dtype=np.uint32).view(np.float32),
        np.asarray(b, dtype=np.uint32).view(np.float32),
        dtype=np.float32,
    )
    return np.asarray(result, dtype=np.float32).view(np.uint32)


def _fp32_mul_array(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    result = np.multiply(
        np.asarray(a, dtype=np.uint32).view(np.float32),
        np.asarray(b, dtype=np.uint32).view(np.float32),
        dtype=np.float32,
    )
    return np.asarray(result, dtype=np.float32).view(np.uint32)


def _fp32_sub_array(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return _fp32_add_array(a, np.asarray(b, dtype=np.uint32) ^ 0x80000000)


def _q26_to_fp32_array(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=np.int64)
    result = np.zeros(values.shape, dtype=np.uint32)
    nonzero = values > 0
    if not np.any(nonzero):
        return result
    selected = values[nonzero]
    bit_idx = np.floor(np.log2(selected.astype(np.float64))).astype(np.int64)
    residual = selected - (np.int64(1) << bit_idx)
    mantissa = np.where(
        bit_idx < 23,
        residual << (23 - bit_idx),
        residual >> (bit_idx - 23),
    )
    exponent = 127 + bit_idx - 26
    result[nonzero] = (
        (exponent.astype(np.uint32) << 23)
        | (mantissa.astype(np.uint32) & 0x7FFFFF)
    )
    return result


def _fp32_to_q8_23_array(bits: np.ndarray) -> np.ndarray:
    bits = np.asarray(bits, dtype=np.uint32)
    exponent = ((bits >> 23) & 0xFF).astype(np.int64)
    mantissa = (np.uint64(1) << 23) | (bits & 0x7FFFFF).astype(np.uint64)
    shift = exponent - 127
    left_shift = np.maximum(shift, 0).astype(np.uint64)
    right_shift = np.maximum(-shift, 0).astype(np.uint64)
    scaled_left = mantissa << left_shift
    scaled_right = mantissa >> right_shift
    scaled = np.where(shift >= 0, scaled_left, scaled_right).astype(np.int64)
    negative = (bits & 0x80000000) != 0
    return np.where(negative, -scaled, scaled)


def exp_lookup_bits_array(x: np.ndarray, lut: np.ndarray) -> np.ndarray:
    """Vectorized equivalent of exp_lookup_bits with the same LUT contract."""
    x = np.asarray(x, dtype=np.uint32)
    x_value = x.view(np.float32)
    result = np.zeros(x.shape, dtype=np.uint32)
    positive = x_value > np.float32(0.0)
    result[positive] = FP32_ONE
    valid = (x_value >= np.float32(-8.0)) & (x_value <= np.float32(0.0))
    if not np.any(valid):
        return result

    valid_bits = x[valid]
    x_q = _fp32_to_q8_23_array(valid_bits)
    idx_num = (x_q + (8 << 23)) * 1023
    idx = np.clip(idx_num >> 26, 0, 1023).astype(np.int64)
    rem = idx_num - (idx << 26)
    edge = idx >= 1023

    lut = np.asarray(lut, dtype=np.uint32)
    out = np.empty(idx.shape, dtype=np.uint32)
    out[edge] = lut[1023]
    interior = ~edge
    if np.any(interior):
        lo = lut[idx[interior]]
        hi = lut[idx[interior] + 1]
        frac = _q26_to_fp32_array(rem[interior])
        delta = _fp32_sub_array(hi, lo)
        out[interior] = _fp32_add_array(
            lo, _fp32_mul_array(delta, frac)
        )
    result[valid] = out
    return result


def recip_lut_bits_array(value: np.ndarray, lut: np.ndarray) -> np.ndarray:
    value = np.asarray(value, dtype=np.uint32)
    exponent = (value >> 23) & 0xFF
    fraction = value & 0x7FFFFF
    result = (((253 - exponent) & 0xFF) << 23) | np.asarray(
        lut, dtype=np.uint32
    )[fraction >> 15]
    exact_power = fraction == 0
    result[exact_power] = ((254 - exponent[exact_power]) & 0xFF) << 23
    return result.astype(np.uint32)


def _score_block_vectorized(
    q_block: np.ndarray, k_block: np.ndarray
) -> np.ndarray:
    """Score block with RTL accumulation order and vectorized outer loops."""
    q_fp = _bf16_to_fp32_array(q_block)
    k_fp = _bf16_to_fp32_array(k_block)
    rows, cols = q_block.shape[0], k_block.shape[0]
    result = np.zeros((rows, cols), dtype=np.uint32)
    for dim in range(HEAD_DIM):
        product = np.multiply(
            q_fp[:, dim, np.newaxis],
            k_fp[np.newaxis, :, dim],
            dtype=np.float32,
        )
        result = _fp32_add_array(
            result, np.asarray(product, dtype=np.float32).view(np.uint32)
        )
    return result


def _update_online_vectorized(
    m_state: np.ndarray,
    l_state: np.ndarray,
    o_acc: np.ndarray,
    scores: np.ndarray,
    v_block: np.ndarray,
    *,
    q_abs_start: int,
    kv_abs_start: int,
    causal: bool,
    kv_tile_first: bool,
    exp_lut: np.ndarray,
) -> None:
    rows, cols = scores.shape
    scores_scaled = _fp32_mul_array(scores, INV_SQRT_D)
    valid = np.ones((rows, cols), dtype=bool)
    if causal:
        q_pos = q_abs_start + np.arange(rows, dtype=np.int64)
        kv_pos = kv_abs_start + np.arange(cols, dtype=np.int64)
        valid = kv_pos[np.newaxis, :] <= q_pos[:, np.newaxis]

    masked_scores = scores_scaled.copy()
    masked_scores[~valid] = FP32_NEG_INF
    row_max_values = masked_scores.view(np.float32).max(axis=1)
    row_max = np.asarray(row_max_values, dtype=np.float32).view(np.uint32)

    if kv_tile_first:
        new_m = row_max
        correction = np.zeros_like(new_m)
    else:
        old_m_value = m_state.view(np.float32)
        row_max_value = row_max.view(np.float32)
        new_m = np.where(
            old_m_value >= row_max_value, m_state, row_max
        ).astype(np.uint32)
        correction = exp_lookup_bits_array(
            _fp32_sub_array(m_state, new_m), exp_lut
        )

    shifted = _fp32_sub_array(masked_scores, new_m[:, np.newaxis])
    p_bits = exp_lookup_bits_array(shifted, exp_lut)
    p_bits[~valid] = FP32_ZERO
    row_sum = np.zeros(rows, dtype=np.uint32)
    for col in range(cols):
        row_sum = _fp32_add_array(row_sum, p_bits[:, col])

    if kv_tile_first:
        new_l = row_sum
    else:
        new_l = _fp32_add_array(
            _fp32_mul_array(l_state, correction), row_sum
        )

    p_fp = _bf16_to_fp32_array((p_bits >> 16).astype(np.uint16))
    v_fp = _bf16_to_fp32_array(v_block)
    delta = np.zeros((rows, HEAD_DIM), dtype=np.uint32)
    for col in range(cols):
        product = np.multiply(
            p_fp[:, col, np.newaxis],
            v_fp[col, np.newaxis, :],
            dtype=np.float32,
        )
        delta = _fp32_add_array(
            delta, np.asarray(product, dtype=np.float32).view(np.uint32)
        )
    o_acc[...] = _fp32_add_array(
        _fp32_mul_array(o_acc, correction[:, np.newaxis]), delta
    )
    m_state[...] = new_m
    l_state[...] = new_l


def attention_gqa_rtl_vectorized(
    q_heads: np.ndarray,
    k_heads: np.ndarray,
    v_heads: np.ndarray,
    *,
    causal: bool,
    q_pos_base: int,
    kv_pos_base: int,
    exp_lut_path: Path,
    recip_lut_path: Path,
    q_head_start: int = 0,
    q_head_limit: int | None = None,
) -> np.ndarray:
    """Fast CPU RTL-contract model retaining the scalar accumulation order."""
    seq_len = int(q_heads.shape[1])
    exp_lut = np.asarray(load_exp_lut(exp_lut_path), dtype=np.uint32)
    recip_lut = np.asarray(load_recip_lut(recip_lut_path), dtype=np.uint32)
    output = np.zeros_like(q_heads, dtype=np.uint16)

    head_start = max(0, q_head_start)
    head_count = N_Q_HEADS if q_head_limit is None else min(
        N_Q_HEADS, head_start + q_head_limit
    )
    for kv_head in range(N_KV_HEADS):
        for group_head in range(GQA_GROUP_SIZE):
            q_head = kv_head * GQA_GROUP_SIZE + group_head
            if q_head < head_start:
                continue
            if q_head >= head_count:
                break
            for q_tile_start in range(0, seq_len, TILE_Q):
                q_tile_rows = min(TILE_Q, seq_len - q_tile_start)
                q_microtiles = (q_tile_rows + 15) // 16
                for micro in range(q_microtiles):
                    q_rows = min(16, q_tile_rows - micro * 16)
                    m_state = np.full(q_rows, FP32_NEG_INF, dtype=np.uint32)
                    l_state = np.zeros(q_rows, dtype=np.uint32)
                    o_acc = np.zeros((q_rows, HEAD_DIM), dtype=np.uint32)
                    q_start = q_tile_start + micro * 16
                    for kv_tile_start in range(0, seq_len, TILE_KV):
                        if causal and (
                            q_pos_base + q_tile_start + q_tile_rows - 1
                            < kv_pos_base + kv_tile_start
                        ):
                            break
                        kv_cols = min(TILE_KV, seq_len - kv_tile_start)
                        for kv_sub_start in range(0, kv_cols, 16):
                            cols = min(16, kv_cols - kv_sub_start)
                            q_block = q_heads[
                                q_head, q_start : q_start + q_rows, :
                            ]
                            k_block = k_heads[
                                kv_head,
                                kv_tile_start + kv_sub_start :
                                kv_tile_start + kv_sub_start + cols,
                                :,
                            ]
                            v_block = v_heads[
                                kv_head,
                                kv_tile_start + kv_sub_start :
                                kv_tile_start + kv_sub_start + cols,
                                :,
                            ]
                            scores = _score_block_vectorized(q_block, k_block)
                            _update_online_vectorized(
                                m_state,
                                l_state,
                                o_acc,
                                scores,
                                v_block,
                                q_abs_start=q_pos_base + q_start,
                                kv_abs_start=kv_pos_base + kv_tile_start + kv_sub_start,
                                causal=causal,
                                kv_tile_first=(
                                    kv_tile_start == 0 and kv_sub_start == 0
                                ),
                                exp_lut=exp_lut,
                            )
                    normalized = _fp32_mul_array(
                        o_acc, recip_lut_bits_array(l_state, recip_lut)[:, None]
                    )
                    normalized_value = normalized.view(np.float32)
                    upper = (normalized.view(np.uint32) >> 16) & 0xFFFF
                    round_up = (
                        ((normalized.view(np.uint32) >> 15) & 1)
                        & (
                            ((normalized.view(np.uint32) & 0x7FFF) != 0)
                            | ((upper & 1) != 0)
                        )
                    )
                    output[
                        q_head, q_start : q_start + q_rows, :
                    ] = (upper + round_up).astype(np.uint16)
    return output


def attention_gqa_rtl(
    q_heads: np.ndarray,
    k_heads: np.ndarray,
    v_heads: np.ndarray,
    *,
    causal: bool,
    q_pos_base: int,
    kv_pos_base: int,
    exp_lut_path: Path,
    recip_lut_path: Path,
    q_head_start: int = 0,
    q_head_limit: int | None = None,
) -> np.ndarray:
    """Generate raw BF16 outputs using the synthesis-path arithmetic contract."""
    seq_len = int(q_heads.shape[1])
    exp_lut = load_exp_lut(exp_lut_path)
    recip_lut = load_recip_lut(recip_lut_path)
    output = np.zeros_like(q_heads, dtype=np.uint16)

    head_start = max(0, q_head_start)
    head_count = N_Q_HEADS if q_head_limit is None else min(N_Q_HEADS, head_start + q_head_limit)
    for kv_head in range(N_KV_HEADS):
        for group_head in range(GQA_GROUP_SIZE):
            q_head = kv_head * GQA_GROUP_SIZE + group_head
            if q_head < head_start:
                continue
            if q_head >= head_count:
                break
            for q_tile_start in range(0, seq_len, TILE_Q):
                q_tile_rows = min(TILE_Q, seq_len - q_tile_start)
                q_microtiles = (q_tile_rows + 15) // 16
                for micro in range(q_microtiles):
                    q_rows = min(16, q_tile_rows - micro * 16)
                    m_state = [FP32_NEG_INF] * q_rows
                    l_state = [FP32_ZERO] * q_rows
                    o_acc = np.zeros((q_rows, HEAD_DIM), dtype=np.uint32)
                    q_start = q_tile_start + micro * 16
                    for kv_tile_start in range(0, seq_len, TILE_KV):
                        if causal and (
                            q_pos_base + q_tile_start + q_tile_rows - 1
                            < kv_pos_base + kv_tile_start
                        ):
                            break
                        kv_cols = min(TILE_KV, seq_len - kv_tile_start)
                        for kv_sub_start in range(0, kv_cols, 16):
                            cols = min(16, kv_cols - kv_sub_start)
                            q_block = q_heads[
                                q_head, q_start : q_start + q_rows, :
                            ]
                            k_block = k_heads[
                                kv_head,
                                kv_tile_start + kv_sub_start :
                                kv_tile_start + kv_sub_start + cols,
                                :,
                            ]
                            v_block = v_heads[
                                kv_head,
                                kv_tile_start + kv_sub_start :
                                kv_tile_start + kv_sub_start + cols,
                                :,
                            ]
                            scores = _score_block(q_block, k_block)
                            _update_online(
                                m_state,
                                l_state,
                                o_acc,
                                scores,
                                v_block,
                                q_abs_start=q_pos_base + q_start,
                                kv_abs_start=kv_pos_base + kv_tile_start + kv_sub_start,
                                causal=causal,
                                kv_tile_first=(
                                    kv_tile_start == 0 and kv_sub_start == 0
                                ),
                                exp_lut=exp_lut,
                            )
                    for row in range(q_rows):
                        for dim in range(HEAD_DIM):
                            normalized = fp32_mul_bits(
                                int(o_acc[row, dim]),
                                recip_lut_bits(l_state[row], recip_lut),
                            )
                            output[q_head, q_start + row, dim] = fp32_to_bf16_bits(
                                normalized
                            )
    return output
