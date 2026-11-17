#!/usr/bin/env python3
"""CPU RTL-contract BF16 benchmark, with optional CPUFreq matching.

Run from a repository checkout on KV260. This measures software emulation,
not native BF16 instructions or an optimized general-purpose CPU kernel.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Import first: board_performance configures BLAS threading before NumPy loads.
from sw.board_performance import (  # noqa: E402
    _sha256, _stats, collect_environment, cpu_attention_numpy,
    detect_cpu_clock_mhz, discover_cases,
)
import numpy as np  # noqa: E402
from python_godel.attention_rtl_golden import attention_gqa_rtl_vectorized  # noqa: E402


@contextmanager
def matched_cpu_clock(core: int, target_mhz: float, attempt: bool):
    """Change only a supported CPUFreq setting; always restore on exit."""
    policy = Path(f"/sys/devices/system/cpu/cpu{core}/cpufreq")
    status = {"requested_mhz": target_mhz, "attempted": attempt,
              "matched": False, "reason": "not requested"}
    saved = {}
    changed = False
    try:
        if attempt:
            try:
                frequencies = [int(v) for v in
                               (policy / "scaling_available_frequencies").read_text().split()]
                status["available_khz"] = frequencies
                target = round(target_mhz * 1000)
                governors = (policy / "scaling_available_governors").read_text().split()
                if target not in frequencies:
                    status["reason"] = "target is not an advertised CPUFreq operating point"
                elif "userspace" not in governors:
                    status["reason"] = "userspace governor unavailable"
                else:
                    for name in ("scaling_governor", "scaling_setspeed"):
                        saved[name] = (policy / name).read_text().strip()
                    # Mark before writing so a partial failure also restores state.
                    changed = True
                    (policy / "scaling_governor").write_text("userspace")
                    (policy / "scaling_setspeed").write_text(str(target))
                    time.sleep(0.1)
                    observed = detect_cpu_clock_mhz(core)
                    status["observed_mhz"] = observed
                    status["matched"] = observed is not None and abs(observed-target_mhz) <= 0.001
                    status["reason"] = "matched" if status["matched"] else "readback did not match target"
            except (OSError, ValueError) as exc:
                status["reason"] = f"CPUFreq unavailable or request failed: {exc}"
                if changed:
                    # Do not benchmark in a partially configured state.
                    raise RuntimeError(status["reason"]) from exc
        print("CPU frequency:", json.dumps(status), flush=True)
        yield status
    finally:
        if changed:
            try:
                if saved.get("scaling_setspeed", "").isdigit():
                    (policy / "scaling_setspeed").write_text(saved["scaling_setspeed"])
            finally:
                (policy / "scaling_governor").write_text(saved["scaling_governor"])


def normalize_cpu_samples(times_ms, clocks_before, clocks_after, target_mhz):
    """Only estimate cycles when both frequency snapshots agree per sample."""
    stable = all(a is not None and b is not None and a > 0 and b > 0
                 and math.isclose(a, b, abs_tol=0.001, rel_tol=0)
                 for a, b in zip(clocks_before, clocks_after))
    if not stable:
        return {"valid": False, "reason": "CPU frequency missing or changed across a sample",
                "target_mhz": target_mhz, "estimated_cycles": None,
                "normalized_wall_ms": None}
    cycles = [t * f * 1000 for t, f in zip(times_ms, clocks_before)]
    return {"valid": True, "target_mhz": target_mhz,
            "estimated_cycles": _stats(cycles),
            "normalized_wall_ms": _stats([c / (target_mhz * 1000) for c in cycles]),
            "note": "wall-time frequency-scaling estimate, not PMU cycles or measured low-frequency latency; assumes invariant cycle count"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case-set", required=True, action="append", metavar="LABEL=DIRECTORY")
    parser.add_argument("--lengths", nargs="+", type=int, default=[1])
    parser.add_argument("--causal-only", action="store_true")
    parser.add_argument("--cpu-core", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--target-mhz", type=float, default=71.427857)
    parser.add_argument("--try-match-clock", action="store_true")
    parser.add_argument("--fpga-performance", type=Path, help="optional existing performance.json; case SHA256 must match")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 1 or args.warmup < 0 or not math.isfinite(args.target_mhz) or args.target_mhz <= 0:
        parser.error("require repeats >= 1, warmup >= 0 and finite target-mhz > 0")
    if args.output.exists():
        parser.error("output already exists; choose a new evidence file")
    sets = []
    for item in args.case_set:
        label, sep, directory = item.partition("=")
        if not sep or not label or not directory:
            parser.error("case-set must be LABEL=DIRECTORY")
        sets.append((label, Path(directory)))
    cases = discover_cases(sets, lengths=args.lengths,
                           modes=(True,) if args.causal_only else (True, False))
    reference = None
    if args.fpga_performance:
        reference = json.loads(args.fpga_performance.read_text())
    import os
    os.sched_setaffinity(0, {args.cpu_core})
    root = Path(__file__).resolve().parents[1]
    exp = root / "VV/data/exp_lut.hex"
    recip = root / "VV/data/recip_lut.hex"
    report = {"schema": "lara-cpu-bf16-v1", "results": [],
              "definition": "CPU software emulation of RTL BF16 multiply/FP32 accumulate, LUT softmax and RTL rounding; not native BF16 performance",
              "normalization_scope": "CPU only; FPGA host-side service was not remeasured at the normalized CPU clock",
              "lut_sha256": {str(p.relative_to(root)): _sha256(p) for p in (exp, recip)}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    failed = False
    with matched_cpu_clock(args.cpu_core, args.target_mhz, args.try_match_clock) as clock_status:
        report["frequency_request"] = clock_status
        report["environment_before"] = collect_environment()
        for case in cases:
            row = {"case_path": str(case.path), "case_sha256": _sha256(case.path),
                   "seq_len": case.seq_len, "causal": case.causal,
                   "q_pos_base": case.q_pos_base, "kv_pos_base": case.kv_pos_base}
            for mode in ("rtl_bf16_emulated", "numpy_fp32"):
                def run():
                    kwargs = dict(causal=case.causal, q_pos_base=case.q_pos_base,
                                  kv_pos_base=case.kv_pos_base)
                    if mode == "rtl_bf16_emulated":
                        return attention_gqa_rtl_vectorized(case.q, case.k, case.v,
                            **kwargs, exp_lut_path=exp, recip_lut_path=recip)
                    return cpu_attention_numpy(case.q, case.k, case.v, **kwargs)
                print(f"L{case.seq_len} causal={case.causal} {mode}", flush=True)
                for _ in range(args.warmup):
                    run()
                times, cpu_times, before, after = [], [], [], []
                all_exact = True
                for _ in range(args.repeats):
                    before.append(detect_cpu_clock_mhz(args.cpu_core))
                    cpu_started_ns = time.process_time_ns()
                    started = time.perf_counter_ns()
                    actual = run()
                    times.append((time.perf_counter_ns()-started)/1e6)
                    cpu_times.append((time.process_time_ns()-cpu_started_ns)/1e6)
                    after.append(detect_cpu_clock_mhz(args.cpu_core))
                    if mode == "rtl_bf16_emulated" and not np.array_equal(actual, case.expected):
                        failed = True
                        all_exact = False
                data = {"wall_ms": _stats(times), "samples_ms": times,
                        "process_cpu_ms": _stats(cpu_times),
                        "clock_before_mhz": before, "clock_after_mhz": after,
                        "normalization": normalize_cpu_samples(times, before, after, args.target_mhz)}
                norm = data["normalization"]
                at_target = all(f is not None and abs(f-args.target_mhz) <= 0.001
                                for f in before+after)
                data["target_frequency_result"] = {
                    "kind": "measured" if at_target else "estimated" if norm["valid"] else "unavailable",
                    "frequency_mhz": args.target_mhz,
                    "wall_ms": data["wall_ms"] if at_target else norm["normalized_wall_ms"],
                }
                if mode == "rtl_bf16_emulated":
                    data["bit_exact_expected"] = all_exact
                    data["mismatch_count"] = int(np.count_nonzero(actual != case.expected))
                else:
                    from sw.attn_driver import bf16_u16_to_fp32
                    data["max_abs_vs_expected"] = float(np.max(np.abs(actual-bf16_u16_to_fp32(case.expected))))
                row[mode] = data
            if reference:
                matches = [r for r in reference["results"] if r["case_sha256"] == row["case_sha256"]]
                if len(matches) != 1:
                    raise ValueError("FPGA reference must contain exactly one matching case SHA256")
                r = matches[0]
                if not r["correctness"]["fpga_bit_exact_expected"]:
                    raise ValueError("FPGA reference case did not pass correctness")
                row["fpga_reference"] = {"source": str(args.fpga_performance),
                    "source_sha256": _sha256(args.fpga_performance),
                    "artifacts": reference.get("artifacts"),
                    "pl_clock_mhz": r["fpga"]["pl_clock_mhz"],
                    "host_to_host_attention_ms": r["fpga"]["host_to_host_attention_ms"],
                    "pl_transaction_ms_from_cycles": r["fpga"]["pl_transaction_ms_from_cycles"]}
            report["results"].append(row)
            args.output.write_text(json.dumps(report, indent=2)+"\n")
        report["environment_after"] = collect_environment()
    report["environment_restored"] = collect_environment()
    args.output.write_text(json.dumps(report, indent=2)+"\n")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
