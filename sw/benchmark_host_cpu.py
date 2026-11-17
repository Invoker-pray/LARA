#!/usr/bin/env python3
"""Run the board's two CPU algorithms on a host; auto-discover repo cases.

Frequency-normalized timings use sampled sysfs frequency, not PMU cycles.
Neither algorithm requires PYNQ hardware or a bitstream.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# Configure BLAS before NumPy loads, as in the board benchmark.
from sw.board_performance import (  # noqa: E402
    _sha256, _stats, collect_environment, cpu_attention_numpy,
    detect_cpu_clock_mhz, discover_cases,
)
import numpy as np  # noqa: E402
from python_godel.attention_rtl_golden import attention_gqa_rtl_vectorized  # noqa: E402


def default_case_sets(root=ROOT):
    return [("q31kv7", root / "board_cases_rtl_contract_v2.6_q31_kv7"),
            ("q3kv3", root / "board_cases_rtl_contract_v2.6_q3_kv3")]


def choose_core(allowed):
    """Prefer the highest advertised maximum clock (P-core on hybrid hosts)."""
    def maximum(core):
        try:
            return int(Path(f"/sys/devices/system/cpu/cpu{core}/cpufreq/cpuinfo_max_freq").read_text())
        except (OSError, ValueError):
            return 0
    return max(sorted(allowed), key=maximum)


def frequency_estimate(trace, start_ns, end_ns, target_mhz):
    """Trapezoid-integrate sampled MHz over wall time; explicitly approximate."""
    if len(trace) < 2 or end_ns <= start_ns or any(f is None or not math.isfinite(f) or f <= 0 for _, f in trace):
        return {"valid": False, "reason": "missing frequency samples or invalid interval"}
    times = np.asarray([t for t, _ in trace], dtype=np.float64)
    frequencies = np.asarray([f for _, f in trace], dtype=np.float64)
    if np.any(np.diff(times) <= 0):
        raise ValueError("frequency samples must have increasing timestamps")
    interior = times[(times > start_ns) & (times < end_ns)]
    points = np.concatenate(([start_ns], interior, [end_ns]))
    values = np.interp(points, times, frequencies)
    # MHz * ns / 1000 = estimated cycles, NOT measured PMU cycles.
    cycles = float(np.sum((values[:-1] + values[1:]) * 0.5 * np.diff(points)) / 1000)
    elapsed_ms = (end_ns-start_ns)/1e6
    return {"valid": True, "method": "time_weighted_sysfs_frequency_estimate",
            "estimated_cycles": cycles, "time_weighted_mhz": cycles/(elapsed_ms*1000),
            "target_mhz": target_mhz, "normalized_wall_ms": cycles/(target_mhz*1000),
            "sampled_min_mhz": float(min(frequencies)),
            "sampled_max_mhz": float(max(frequencies)),
            "max_sample_gap_ms": float(max(np.diff(times))/1e6),
            "note": "Approximate frequency integration, not PMU cycles or measured low-frequency latency; assumes invariant cycle count. Sampling misses between-read frequency changes."}


def timed_call(function, core, target_mhz, interval_ms):
    trace = []
    stop = threading.Event()

    def sample():
        before = time.perf_counter_ns()
        clock = detect_cpu_clock_mhz(core)
        after = time.perf_counter_ns()
        trace.append(((before+after)//2, clock))

    def sampler():
        while not stop.wait(interval_ms/1000):
            sample()

    sample()
    worker = threading.Thread(target=sampler, daemon=True)
    worker.start()
    cpu_start = time.process_time_ns()
    start = time.perf_counter_ns()
    try:
        result = function()
    finally:
        end = time.perf_counter_ns()
        cpu_end = time.process_time_ns()
        stop.set()
        worker.join()
        sample()
    trace.sort()
    return result, {"wall_ms": (end-start)/1e6,
                    "process_cpu_ms": (cpu_end-cpu_start)/1e6,
                    "frequency_samples": trace,
                    "frequency_estimate": frequency_estimate(trace, start, end, target_mhz)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case-set", action="append", metavar="LABEL=DIRECTORY")
    parser.add_argument("--lengths", nargs="+", type=int, default=[1, 16, 32, 64, 128])
    parser.add_argument("--causal-only", action="store_true")
    parser.add_argument("--cpu-core", type=int)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--target-mhz", type=float, default=71.427857)
    parser.add_argument("--frequency-sample-ms", type=float, default=5.0)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--board-report", type=Path,
                        default=ROOT/'temp/cpu_bf16_study_20261117/lara_cpu_bf16_20261117/cpu_bf16.json')
    args = parser.parse_args()
    if args.repeats < 1 or args.warmup < 0 or any(not math.isfinite(v) or v <= 0 for v in [args.target_mhz, args.frequency_sample_ms]):
        parser.error("require repeats>=1, warmup>=0, finite positive frequencies/intervals")
    sets = default_case_sets()
    if args.case_set:
        sets = []
        for item in args.case_set:
            label, sep, directory = item.partition('=')
            if not sep or not label or not directory:
                parser.error("case-set must be LABEL=DIRECTORY")
            sets.append((label, Path(directory)))
    for _, path in sets:
        if not path.is_dir():
            parser.error(f"missing case directory {path}; supply --case-set LABEL=DIRECTORY")
    cases = discover_cases(sets, lengths=args.lengths,
                           modes=(True,) if args.causal_only else (True, False))
    allowed = os.sched_getaffinity(0)
    core = args.cpu_core if args.cpu_core is not None else choose_core(allowed)
    if core not in allowed:
        parser.error(f"CPU {core} not in process affinity {sorted(allowed)}")
    os.sched_setaffinity(0, {core})
    output = args.output_dir or ROOT/'temp'/('host_cpu_bf16_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    output.mkdir(parents=True, exist_ok=False)
    board = json.loads(args.board_report.read_text()) if args.board_report.is_file() else None
    cpuinfo = Path('/proc/cpuinfo').read_text()
    model = next((line.split(':', 1)[1].strip() for line in cpuinfo.splitlines() if line.startswith('model name')), 'unknown')
    report = {"schema": "lara-host-cpu-bf16-v1", "cpu_model": model, "cpu_core": core,
              "target_mhz": args.target_mhz, "warmup": args.warmup, "repeats": args.repeats,
              "frequency_method": "sysfs samples integrated over each timed call; approximate, no PMU",
              "definitions": {
                  "rtl_bf16_emulated": "Same board Python/NumPy RTL-contract simulation, including LUT reads, software bit operations and allocations; not optimized/native BF16 kernel performance",
                  "numpy_fp32": "BF16 inputs converted to FP32; NumPy matmul and standard exp/softmax",
                  "comparison": "Actual times compare different CPU architectures; normalized times are hypothetical. FPGA E2E PS service remains at the board's actual CPU clock."},
              "environment_before": collect_environment(), "results": [],
              "source_sha256": {p: _sha256(ROOT/p) for p in ['sw/benchmark_host_cpu.py', 'sw/board_performance.py', 'python_godel/attention_rtl_golden.py', 'VV/data/exp_lut.hex', 'VV/data/recip_lut.hex']}}
    (output/'cpuinfo.txt').write_text(cpuinfo)
    failed = False
    print(f"HOST {model}, CPU {core}, output {output}", flush=True)
    for case in cases:
        row = {"case_sha256": _sha256(case.path), "case_path": str(case.path),
               "seq_len": case.seq_len, "causal": case.causal,
               "q_pos_base": case.q_pos_base, "kv_pos_base": case.kv_pos_base}
        for mode in ['rtl_bf16_emulated', 'numpy_fp32']:
            def run():
                kwargs = dict(causal=case.causal, q_pos_base=case.q_pos_base, kv_pos_base=case.kv_pos_base)
                if mode == 'numpy_fp32':
                    return cpu_attention_numpy(case.q, case.k, case.v, **kwargs)
                return attention_gqa_rtl_vectorized(case.q, case.k, case.v, **kwargs,
                    exp_lut_path=ROOT/'VV/data/exp_lut.hex', recip_lut_path=ROOT/'VV/data/recip_lut.hex')
            for _ in range(args.warmup):
                run()
            samples = []
            exact = True
            for _ in range(args.repeats):
                actual, sample = timed_call(run, core, args.target_mhz, args.frequency_sample_ms)
                samples.append(sample)
                if mode == 'rtl_bf16_emulated':
                    exact = exact and np.array_equal(actual, case.expected)
            estimates = [s['frequency_estimate'] for s in samples]
            data = {"wall_ms": _stats([s['wall_ms'] for s in samples]), "samples": samples,
                    "normalized_wall_ms": _stats([s['normalized_wall_ms'] for s in estimates]) if all(s['valid'] for s in estimates) else None}
            if mode == 'rtl_bf16_emulated':
                data['bit_exact_expected'] = bool(exact)
                failed = failed or not exact
            row[mode] = data
            print(f"L{case.seq_len} q{case.q_pos_base} causal={case.causal} {mode}: {data['wall_ms']['median']:.3f} ms" + (f" exact={exact}" if mode == 'rtl_bf16_emulated' else ''), flush=True)
        if board:
            matches = [r for r in board['results'] if r['case_sha256'] == row['case_sha256']]
            if len(matches) != 1:
                raise ValueError('board report must have exactly one matching case SHA256')
            row['board_reference'] = matches[0]
        report['results'].append(row)
        (output/'performance.json').write_text(json.dumps(report, indent=2)+'\n')
    report['environment_after'] = collect_environment()
    report['board_report_sha256'] = _sha256(args.board_report) if board else None
    (output/'performance.json').write_text(json.dumps(report, indent=2)+'\n')
    with (output/'comparison.csv').open('w') as stream:
        fields=['length', 'q_pos', 'causal', 'algorithm', 'host_actual_ms', 'host_71mhz_estimate_ms', 'board_actual_ms', 'board_71mhz_estimate_ms', 'fpga_e2e_ms']
        writer=csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in report['results']:
            for mode in ['rtl_bf16_emulated', 'numpy_fp32']:
                h=row[mode]; b=row.get('board_reference', {}).get(mode, {})
                f=row.get('board_reference', {}).get('fpga_reference', {})
                writer.writerow(dict(length=row['seq_len'], q_pos=row['q_pos_base'], causal=row['causal'], algorithm=mode,
                    host_actual_ms=h['wall_ms']['median'], host_71mhz_estimate_ms=h['normalized_wall_ms']['median'] if h['normalized_wall_ms'] else '',
                    board_actual_ms=b.get('wall_ms', {}).get('median', ''),
                    board_71mhz_estimate_ms=b.get('normalization', {}).get('normalized_wall_ms', {}).get('median', ''),
                    fpga_e2e_ms=f.get('host_to_host_attention_ms', {}).get('median', '')))
    print(f"BF16 bit-exact: {sum(r['rtl_bf16_emulated']['bit_exact_expected'] for r in report['results'])}/{len(cases)}; output: {output}", flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
