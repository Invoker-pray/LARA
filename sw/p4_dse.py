#!/usr/bin/env python3
"""Reproducible cycle/resource model for the three LARA v2.5 P4 candidates.

Measured inputs are labeled separately from analytical extrapolations.  This
model decides whether a candidate may advance to RTL; it never marks a design
accepted without matching post-route evidence.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

TILE_ROWS = 16
TILE_COLS = 16
TILE_Q = 32
TILE_KV = 64
HEAD_DIM = 128
TILE_SPLIT_FACTOR = 2

DEVICE_LUT = 117_120
DEVICE_FF = 234_240
DEVICE_DSP = 1_248

P2_TOP_LUT = 95_356
P2_TOP_FF = 56_938
P2_TOP_DSP = 165
P2_MAC_LUT = 63_787
P2_MAC_DSP = 128
P2_SOFTMAX_LUT = 10_086
P2_SOFTMAX_FF = 23_000

SOFTMAX_16X16_CYCLES = 626
P2_PHASEA_32X64_CYCLES = 5_290
P2_PHASEA_32X64_BACKPRESSURE_CYCLES = 5_310
CONTROLLER_TRANSITION_CYCLES = 3

PROFILE_32X32 = {
    "mainloop_cycles": 4_345,
    "phasea_schedule_cycles": 2_774,
    "qk_run_cycles": 1_024,
    "softmax_inflight_cycles": 2_508,
    "phaseb_run_cycles": 1_024,
    "phaseb_capture_cycles": 32,
    "phaseb_update_cycles": 512,
}
PROFILE_32X64_BASELINE = {
    "mainloop_cycles": 8_429,
    "phasea_schedule_cycles": 5_290,
    "qk_run_cycles": 2_048,
    "softmax_inflight_cycles": 5_016,
    "phaseb_run_cycles": 2_048,
    "phaseb_capture_cycles": 64,
    "phaseb_update_cycles": 1_024,
    "phaseb_wait_cycles": 0,
}
PROFILE_32X64_STREAMING = {
    "mainloop_cycles": 5_809,
    "phasea_schedule_cycles": 5_416,
    "qk_run_cycles": 2_048,
    "softmax_inflight_cycles": 5_016,
    "phaseb_run_cycles": 2_048,
    "phaseb_capture_cycles": 64,
    "phaseb_update_cycles": 1_024,
    "phaseb_wait_cycles": 1_785,
}


def ceil_div(value: int, divisor: int) -> int:
    """Return ceil(value / divisor) for non-negative integers."""
    if value < 0 or divisor <= 0:
        raise ValueError("ceil_div requires value >= 0 and divisor > 0")
    return (value + divisor - 1) // divisor


def phaseb_model(
    *,
    tile_cols: int = TILE_COLS,
    active_q_rows: int = TILE_Q,
    active_kv_cols: int = TILE_KV,
    head_dim: int = HEAD_DIM,
    split_factor: int = TILE_SPLIT_FACTOR,
) -> dict[str, int]:
    """Model the current PB_RUN/PB_CAPTURE/PB_UPDATE traversal exactly."""
    q_microtiles = ceil_div(active_q_rows, TILE_ROWS)
    kv_subblocks = ceil_div(active_kv_cols, tile_cols)
    dim_subblocks = ceil_div(head_dim, tile_cols)
    tasks = q_microtiles * kv_subblocks * dim_subblocks
    run_per_task = tile_cols * split_factor
    capture_per_task = 1

    update_cycles = 0
    for micro in range(q_microtiles):
        rows = min(TILE_ROWS, active_q_rows - micro * TILE_ROWS)
        update_cycles += rows * kv_subblocks * dim_subblocks

    run_cycles = tasks * run_per_task
    capture_cycles = tasks * capture_per_task
    return {
        "q_microtiles": q_microtiles,
        "kv_subblocks": kv_subblocks,
        "dim_subblocks": dim_subblocks,
        "tasks": tasks,
        "run_cycles_per_task": run_per_task,
        "capture_cycles_per_task": capture_per_task,
        "run_cycles": run_cycles,
        "capture_cycles": capture_cycles,
        "update_cycles": update_cycles,
        "total_cycles": run_cycles + capture_cycles + update_cycles,
    }


def pct(value: int, capacity: int) -> float:
    """Return a stable percentage rounded for reports."""
    return round(100.0 * value / capacity, 3)


def reduction_pct(baseline: int, candidate: int) -> float:
    """Return cycle reduction versus baseline."""
    return round(100.0 * (baseline - candidate) / baseline, 3)


def build_model() -> dict[str, Any]:
    """Build the P4 DSE model and evidence-based advancement decisions."""
    phaseb_16 = phaseb_model()
    baseline_cycles = (
        P2_PHASEA_32X64_CYCLES
        + phaseb_16["total_cycles"]
        + CONTROLLER_TRANSITION_CYCLES
    )

    qk_block_cycles = HEAD_DIM * TILE_SPLIT_FACTOR
    pv_block_cycles = (
        phaseb_16["dim_subblocks"]
        * (
            phaseb_16["run_cycles_per_task"]
            + phaseb_16["capture_cycles_per_task"]
            + TILE_ROWS
        )
    )
    combined_middle_interval = qk_block_cycles + pv_block_cycles
    # Eight score blocks: initial QK; first softmax interval; six middle
    # QK+PV intervals; final softmax followed by the last PV block.
    streaming_model_cycles = (
        qk_block_cycles
        + SOFTMAX_16X16_CYCLES
        + 6 * combined_middle_interval
        + SOFTMAX_16X16_CYCLES
        + pv_block_cycles
        + CONTROLLER_TRANSITION_CYCLES
    )

    dual_lut = P2_TOP_LUT + P2_SOFTMAX_LUT
    dual_ff = P2_TOP_FF + P2_SOFTMAX_FF
    # This optimistic lower bound assumes perfect two-lane load balancing and
    # ignores arbitration overhead; it is used only to show possible benefit.
    dual_phasea_lower_bound = qk_block_cycles + 4 * SOFTMAX_16X16_CYCLES
    dual_cycles_lower_bound = (
        dual_phasea_lower_bound
        + phaseb_16["total_cycles"]
        + CONTROLLER_TRANSITION_CYCLES
    )

    phaseb_32 = phaseb_model(tile_cols=32)
    softmax_16x32_cycles = 513 + 48 + 544 + 33
    mac_16x32_phasea_cycles = 4_834
    mac_16x32_cycles = (
        mac_16x32_phasea_cycles
        + phaseb_32["total_cycles"]
        + CONTROLLER_TRANSITION_CYCLES
    )
    # Even granting an implausibly favorable 50% incremental-LUT scaling for
    # doubling MAC columns exceeds the device.  Actual duplication is worse.
    mac_16x32_extra_lut_lower_bound = ceil_div(P2_MAC_LUT, 2)
    mac_16x32_lut_lower_bound = P2_TOP_LUT + mac_16x32_extra_lut_lower_bound

    return {
        "schema_version": 1,
        "baseline": {
            "configuration": "P2 Phase-A softmax overlap, P3 candidates off",
            "measured_profile_32x32": PROFILE_32X32,
            "measured_profile_32x64": PROFILE_32X64_BASELINE,
            "measured_phasea_32x64_cycles": P2_PHASEA_32X64_CYCLES,
            "measured_phasea_32x64_with_backpressure_cycles": (
                P2_PHASEA_32X64_BACKPRESSURE_CYCLES
            ),
            "phaseb_32x64_model": phaseb_16,
            "controller_transition_cycles": CONTROLLER_TRANSITION_CYCLES,
            "mainloop_32x64_cycles": baseline_cycles,
            "resources_post_route": {
                "lut": P2_TOP_LUT,
                "ff": P2_TOP_FF,
                "dsp": P2_TOP_DSP,
            },
        },
        "candidates": {
            "streaming_fused_pv": {
                "cycle_model": {
                    "qk_cycles_per_block": qk_block_cycles,
                    "pv_cycles_per_block": pv_block_cycles,
                    "softmax_cycles_per_block": SOFTMAX_16X16_CYCLES,
                    "middle_interval_cycles": combined_middle_interval,
                    "predicted_mainloop_cycles": streaming_model_cycles,
                    "predicted_reduction_percent": reduction_pct(
                        baseline_cycles, streaming_model_cycles
                    ),
                    "measured_profile_32x64": PROFILE_32X64_STREAMING,
                    "measured_reduction_percent": reduction_pct(
                        baseline_cycles,
                        PROFILE_32X64_STREAMING["mainloop_cycles"],
                    ),
                },
                "decision": "advance-to-rtl",
                "acceptance_state": "not-accepted-model-only",
                "required_proofs": [
                    "bit-exact P/m/l/correction and final output",
                    "strict correction order",
                    "shared-MAC atomic task arbitration",
                    "output-buffer RAW safety and normalization",
                    "no duplicate ST_AV_DOT computation",
                    "matching clean post-route timing and DRC",
                ],
            },
            "dual_softmax": {
                "optimistic_cycle_lower_bound": {
                    "phasea_cycles": dual_phasea_lower_bound,
                    "mainloop_cycles": dual_cycles_lower_bound,
                    "reduction_percent": reduction_pct(
                        baseline_cycles, dual_cycles_lower_bound
                    ),
                },
                "resource_projection": {
                    "lut": dual_lut,
                    "lut_percent": pct(dual_lut, DEVICE_LUT),
                    "ff": dual_ff,
                    "ff_percent": pct(dual_ff, DEVICE_FF),
                },
                "decision": "reject-resource-model",
                "acceptance_state": "rejected",
                "reason": (
                    "Projected LUT is already above the approximately 90% "
                    "routing-risk gate; the smaller P3 score-inplace design "
                    "occupied 99.17% of CLBs and failed Explore setup."
                ),
            },
            "mac_16x32": {
                "cycle_model": {
                    "softmax_16x32_cycles_per_block": softmax_16x32_cycles,
                    "phasea_cycles": mac_16x32_phasea_cycles,
                    "phaseb": phaseb_32,
                    "mainloop_cycles": mac_16x32_cycles,
                    "reduction_percent": reduction_pct(
                        baseline_cycles, mac_16x32_cycles
                    ),
                },
                "resource_lower_bound": {
                    "incremental_lut": mac_16x32_extra_lut_lower_bound,
                    "top_lut": mac_16x32_lut_lower_bound,
                    "top_lut_percent": pct(mac_16x32_lut_lower_bound, DEVICE_LUT),
                    "mac_dsp_projection": 2 * P2_MAC_DSP,
                },
                "decision": "reject-resource-model",
                "acceptance_state": "rejected",
                "reason": (
                    "Even a favorable half-MAC incremental LUT lower bound "
                    "exceeds device LUT capacity before place/route."
                ),
            },
        },
        "device_capacity": {
            "lut": DEVICE_LUT,
            "ff": DEVICE_FF,
            "dsp": DEVICE_DSP,
        },
        "evidence_scope": {
            "profile_source": "VCS +define+SYNTHESIS tb_attn_top",
            "p2_route_source": "checkpoint/v2.5-phasea-softmax-overlap",
            "p3_congestion_source": (
                "checkpoint/v2.5-p3-softmax-scratch-dse/"
                "step3-score-inplace/explore-route"
            ),
            "model_is_post_route_acceptance": False,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    rendered = json.dumps(build_model(), indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
