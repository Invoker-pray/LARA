#!/usr/bin/env python3
"""Benchmark LARA and a same-board NumPy attention baseline on KV260.

The FPGA metric comes from the RTL cycle counter and the deployed PL clock.
The baseline executes the same bf16-input GQA attention on the KV260 Cortex-A53
with NumPy fp32 matmul/softmax and does not invoke the FPGA accelerator.
"""

from __future__ import annotations

import os

# Set these before importing NumPy so a linked BLAS has deterministic threading.
# Set LARA_CPU_THREADS before launch to benchmark a different CPU thread count.
_cpu_threads = os.environ.get("LARA_CPU_THREADS", "1")
for _name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_name] = _cpu_threads

import argparse
import csv
import hashlib
import json
import platform
import re
import socket
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from attn_driver import (  # noqa: E402
    GQA_GROUP_SIZE,
    HEAD_DIM,
    MAX_SEQ_LEN,
    N_KV_HEADS,
    N_Q_HEADS,
    PL_CLOCK_MHZ,
    AttentionAccelerator,
    bf16_u16_to_fp32,
)


REQUIRED_LENGTHS = (1, 16, 32, 64, 128)
REQUIRED_MODES = (True, False)
OFFICIAL_PAGE = "https://fpt2026.uark.edu/fpt26-design-competition/"
OFFICIAL_GUIDE = "https://github.com/FPT26/Design-Competition-Submission-Guidelines"


@dataclass(frozen=True)
class BoardCase:
    label: str
    path: Path
    q: np.ndarray
    k: np.ndarray
    v: np.ndarray
    expected: np.ndarray
    seq_len: int
    causal: bool
    q_pos_base: int
    kv_pos_base: int


class FreshOverlayRunner:
    """Run each FPGA sample on a newly programmed PL instance."""

    def __init__(self, bitstream: Path, accelerator_factory: Any = AttentionAccelerator) -> None:
        self.bitstream = bitstream
        self.accelerator_factory = accelerator_factory
        self.last_profile: Any | None = None

    def run_attention(self, *args: Any, **kwargs: Any) -> np.ndarray:
        print(f"    Programming fresh Overlay: {self.bitstream}", flush=True)
        with self.accelerator_factory(str(self.bitstream)) as accel:
            if not accel.hw_ready:
                raise RuntimeError("PYNQ hardware is unavailable; run this benchmark on the KV260")
            print("    Overlay ready", flush=True)
            output = accel.run_attention(*args, **kwargs)
            self.last_profile = accel.last_profile
            return output


def _scalar(data: np.lib.npyio.NpzFile, name: str, default: int) -> int:
    value = data.get(name)
    return default if value is None else int(np.asarray(value).item())


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_case(label: str, path: Path) -> BoardCase:
    with np.load(path) as data:
        q = np.ascontiguousarray(data["q_heads"], dtype=np.uint16)
        k = np.ascontiguousarray(data["k_heads"], dtype=np.uint16)
        v = np.ascontiguousarray(data["v_heads"], dtype=np.uint16)
        expected = np.ascontiguousarray(data["expected_o"], dtype=np.uint16)
        seq_len = _scalar(data, "seq_len", int(q.shape[1]))
        causal = bool(_scalar(data, "causal", 1))
        q_pos_base = _scalar(data, "q_pos_base", 0)
        kv_pos_base = _scalar(data, "kv_pos_base", 0)

    expected_q = (N_Q_HEADS, seq_len, HEAD_DIM)
    expected_kv = (N_KV_HEADS, seq_len, HEAD_DIM)
    if q.shape != expected_q or expected.shape != expected_q:
        raise ValueError(f"{path}: expected Q/O shape {expected_q}, got {q.shape}/{expected.shape}")
    if k.shape != expected_kv or v.shape != expected_kv:
        raise ValueError(f"{path}: expected K/V shape {expected_kv}, got {k.shape}/{v.shape}")
    return BoardCase(label, path.resolve(), q, k, v, expected, seq_len, causal, q_pos_base, kv_pos_base)


def discover_cases(
    case_sets: Iterable[tuple[str, Path]],
    *,
    lengths: Iterable[int] = REQUIRED_LENGTHS,
    modes: Iterable[bool] = REQUIRED_MODES,
) -> list[BoardCase]:
    selected_lengths = tuple(lengths)
    selected_modes = tuple(modes)
    if not selected_lengths or not selected_modes:
        raise ValueError("at least one length and causal mode must be selected")
    cases: list[BoardCase] = []
    for label, directory in case_sets:
        if not directory.is_dir():
            raise FileNotFoundError(f"case directory does not exist: {directory}")
        selected: dict[tuple[int, bool], BoardCase] = {}
        for path in sorted(directory.glob("case_*.npz")):
            case = load_case(label, path)
            if case.seq_len not in selected_lengths or case.causal not in selected_modes:
                continue
            key = (case.seq_len, case.causal)
            if key in selected:
                raise ValueError(f"{directory}: duplicate L={case.seq_len}, causal={case.causal}")
            selected[key] = case
        missing = [
            f"L={length} {'causal' if causal else 'noncausal'}"
            for length in selected_lengths
            for causal in selected_modes
            if (length, causal) not in selected
        ]
        if missing:
            raise ValueError(f"{directory}: missing required cases: {', '.join(missing)}")
        cases.extend(
            selected[(length, causal)]
            for length in selected_lengths
            for causal in selected_modes
        )
    return cases


def cpu_attention_numpy(
    q: np.ndarray,
    k: np.ndarray,
    v: np.ndarray,
    *,
    causal: bool,
    q_pos_base: int,
    kv_pos_base: int,
) -> np.ndarray:
    """Standard stable-softmax GQA baseline with bf16 inputs and fp32 compute."""
    qf = bf16_u16_to_fp32(q)
    kf = bf16_u16_to_fp32(k)
    vf = bf16_u16_to_fp32(v)
    length = q.shape[1]
    output = np.empty((N_Q_HEADS, length, HEAD_DIM), dtype=np.float32)
    valid: np.ndarray | None = None
    if causal:
        q_positions = q_pos_base + np.arange(length)
        kv_positions = kv_pos_base + np.arange(length)
        valid = kv_positions[np.newaxis, :] <= q_positions[:, np.newaxis]
        if not np.all(np.any(valid, axis=1)):
            raise ValueError("causal workload contains a query with no valid K/V position")

    scale = np.float32(1.0 / np.sqrt(HEAD_DIM))
    for group in range(N_KV_HEADS):
        first = group * GQA_GROUP_SIZE
        q_group = qf[first:first + GQA_GROUP_SIZE]
        scores = np.matmul(q_group, kf[group].T) * scale
        if valid is not None:
            scores = np.where(valid[np.newaxis, :, :], scores, -np.inf)
        scores -= np.max(scores, axis=-1, keepdims=True)
        np.exp(scores, out=scores)
        scores /= np.sum(scores, axis=-1, keepdims=True)
        output[first:first + GQA_GROUP_SIZE] = np.matmul(scores, vf[group])
    return output


def _stats(values: list[float]) -> dict[str, float]:
    if not values:
        raise ValueError("cannot summarize an empty sample")
    array = np.asarray(values, dtype=np.float64)
    return {
        "min": float(np.min(array)),
        "median": float(np.median(array)),
        "p95": float(np.percentile(array, 95)),
        "max": float(np.max(array)),
    }


def _numeric_error(actual: np.ndarray, reference: np.ndarray) -> dict[str, float]:
    actual64 = np.asarray(actual, dtype=np.float64)
    reference64 = np.asarray(reference, dtype=np.float64)
    delta = actual64 - reference64
    denom = np.maximum(np.abs(reference64), 1.0e-6)
    reference_rms = float(np.sqrt(np.mean(reference64 * reference64)))
    return {
        "max_abs": float(np.max(np.abs(delta))),
        "mean_abs": float(np.mean(np.abs(delta))),
        "rmse": float(np.sqrt(np.mean(delta * delta))),
        "normalized_rmse": float(np.sqrt(np.mean(delta * delta)) / max(reference_rms, 1.0e-12)),
        "max_relative_floor_1e-6": float(np.max(np.abs(delta) / denom)),
    }


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return None


def detect_cpu_clock_mhz(cpu_core: int | None) -> float | None:
    """Read a stable CPU clock snapshot for explicitly labeled cycle estimates."""
    if cpu_core is None and hasattr(os, "sched_getaffinity"):
        affinity = sorted(os.sched_getaffinity(0))
        if len(affinity) == 1:
            cpu_core = affinity[0]
    if cpu_core is None:
        return None
    freq_dir = Path(f"/sys/devices/system/cpu/cpu{cpu_core}/cpufreq")
    for name in ("scaling_cur_freq", "cpuinfo_cur_freq"):
        value = _read_text(freq_dir / name)
        if value and value.isdigit() and int(value) > 0:
            return int(value) / 1000.0
    return None


def collect_environment() -> dict[str, Any]:
    cpu: list[dict[str, Any]] = []
    for cpu_dir in sorted(Path("/sys/devices/system/cpu").glob("cpu[0-9]*")):
        freq_dir = cpu_dir / "cpufreq"
        row: dict[str, Any] = {"cpu": cpu_dir.name}
        for name in ("scaling_cur_freq", "scaling_min_freq", "scaling_max_freq", "scaling_governor"):
            value = _read_text(freq_dir / name)
            if value is not None:
                row[name] = int(value) if value.isdigit() else value
        cpu.append(row)
    thermal: dict[str, int] = {}
    for zone in sorted(Path("/sys/class/thermal").glob("thermal_zone*")):
        value = _read_text(zone / "temp")
        if value and value.lstrip("-").isdigit():
            thermal[zone.name] = int(value)
    try:
        import pynq  # type: ignore

        pynq_version: str | None = getattr(pynq, "__version__", "unknown")
    except ImportError:
        pynq_version = None
    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": sys.version,
        "numpy": np.__version__,
        "pynq": pynq_version,
        "process_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "thread_environment": {
            name: os.environ.get(name)
            for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS")
        },
        "cpu_cpufreq_khz": cpu,
        "thermal_millicelsius": thermal,
    }


def _case_id(case: BoardCase) -> str:
    mode = "causal" if case.causal else "noncausal"
    return f"{case.label}_L{case.seq_len}_q{case.q_pos_base}_kv{case.kv_pos_base}_{mode}"


def benchmark_case(
    accel: AttentionAccelerator,
    case: BoardCase,
    *,
    warmup: int,
    repeats: int,
    timeout_ms: int | None,
    cpu_clock_mhz: float | None = None,
) -> dict[str, Any]:
    case_id = _case_id(case)
    if warmup:
        print(
            f"  WARMUP START {case_id}: FPGA + CPU baseline, repeats={warmup}",
            flush=True,
        )
    for _ in range(warmup):
        accel.run_attention(
            case.q, case.k, case.v, seq_len=case.seq_len,
            causal=case.causal, q_pos_base=case.q_pos_base,
            kv_pos_base=case.kv_pos_base, timeout_ms=timeout_ms,
        )
        cpu_attention_numpy(
            case.q, case.k, case.v, causal=case.causal,
            q_pos_base=case.q_pos_base, kv_pos_base=case.kv_pos_base,
        )
    if warmup:
        print(f"  WARMUP DONE {case_id}", flush=True)

    fpga_profiles: list[dict[str, Any]] = []
    hardware_output: np.ndarray | None = None
    print(f"  FPGA MEASURE START {case_id}: repeats={repeats}", flush=True)
    for _ in range(repeats):
        hardware_output = accel.run_attention(
            case.q, case.k, case.v, seq_len=case.seq_len,
            causal=case.causal, q_pos_base=case.q_pos_base,
            kv_pos_base=case.kv_pos_base, timeout_ms=timeout_ms,
        )
        assert accel.last_profile is not None
        fpga_profiles.append(accel.last_profile.to_dict())
    print(f"  FPGA MEASURE DONE {case_id}", flush=True)

    cpu_ms: list[float] = []
    cpu_output: np.ndarray | None = None
    print(f"  CPU BASELINE START {case_id}: repeats={repeats}", flush=True)
    for _ in range(repeats):
        started_ns = time.perf_counter_ns()
        cpu_output = cpu_attention_numpy(
            case.q, case.k, case.v, causal=case.causal,
            q_pos_base=case.q_pos_base, kv_pos_base=case.kv_pos_base,
        )
        cpu_ms.append((time.perf_counter_ns() - started_ns) / 1.0e6)
    print(f"  CPU BASELINE DONE {case_id}", flush=True)

    assert hardware_output is not None and cpu_output is not None
    mismatch = np.argwhere(hardware_output != case.expected)
    bit_exact = mismatch.size == 0
    first_mismatch: dict[str, Any] | None = None
    if not bit_exact:
        index = tuple(int(value) for value in mismatch[0])
        first_mismatch = {
            "index": index,
            "actual_hex": f"0x{int(hardware_output[index]):04x}",
            "expected_hex": f"0x{int(case.expected[index]):04x}",
        }

    pl_clock_mhz = [float(profile["clock_mhz"]) for profile in fpga_profiles]
    pl_cycles = [float(profile["pl_total_cycles"]) for profile in fpga_profiles]
    pl_mac_cycles = [float(profile["pl_mac_cycles"]) for profile in fpga_profiles]
    pl_stall_cycles = [float(profile["pl_stall_cycles"]) for profile in fpga_profiles]
    pl_counter_valid = all(
        clock > 0 and total > 0 and 0 <= mac <= total and 0 <= stall <= total
        for clock, total, mac, stall in zip(
            pl_clock_mhz, pl_cycles, pl_mac_cycles, pl_stall_cycles
        )
    )
    pl_transaction_ms = (
        [cycles / (clock * 1000.0) for cycles, clock in zip(pl_cycles, pl_clock_mhz)]
        if pl_counter_valid
        else []
    )
    pl_compute_cycles = (
        [total - stall for total, stall in zip(pl_cycles, pl_stall_cycles)]
        if pl_counter_valid
        else []
    )
    pl_compute_ms = [
        cycles / (clock * 1000.0)
        for cycles, clock in zip(pl_compute_cycles, pl_clock_mhz)
    ]
    pl_mac_ms = (
        [cycles / (clock * 1000.0) for cycles, clock in zip(pl_mac_cycles, pl_clock_mhz)]
        if pl_counter_valid
        else []
    )
    pl_stall_ms = (
        [cycles / (clock * 1000.0) for cycles, clock in zip(pl_stall_cycles, pl_clock_mhz)]
        if pl_counter_valid
        else []
    )
    fpga_e2e_ms = [float(profile["attention_total_ms"]) for profile in fpga_profiles]
    cpu_stats = _stats(cpu_ms)
    pl_transaction_stats = _stats(pl_transaction_ms) if pl_counter_valid else None
    pl_compute_stats = _stats(pl_compute_ms) if pl_counter_valid else None
    pl_mac_stats = _stats(pl_mac_ms) if pl_counter_valid else None
    pl_stall_stats = _stats(pl_stall_ms) if pl_counter_valid else None
    e2e_stats = _stats(fpga_e2e_ms)
    cpu_estimated_cycles = (
        [value * cpu_clock_mhz * 1000.0 for value in cpu_ms]
        if cpu_clock_mhz is not None
        else []
    )
    expected_fp32 = bf16_u16_to_fp32(case.expected)
    hardware_fp32 = bf16_u16_to_fp32(hardware_output)

    return {
        "case_id": _case_id(case),
        "case_set": case.label,
        "case_path": str(case.path),
        "case_sha256": _sha256(case.path),
        "seq_len": case.seq_len,
        "causal": case.causal,
        "q_pos_base": case.q_pos_base,
        "kv_pos_base": case.kv_pos_base,
        "warmup": warmup,
        "repeats": repeats,
        "correctness": {
            "fpga_bit_exact_expected": bit_exact,
            "fpga_mismatch_count": int(len(mismatch)),
            "fpga_first_mismatch": first_mismatch,
            "cpu_fp32_vs_expected_bf16": _numeric_error(cpu_output, expected_fp32),
            "cpu_fp32_vs_fpga_bf16": _numeric_error(cpu_output, hardware_fp32),
        },
        "fpga": {
            "pl_clock_mhz": _stats(pl_clock_mhz)["median"],
            "pl_clock_mhz_samples": pl_clock_mhz,
            "pl_clock_mhz_stats": _stats(pl_clock_mhz),
            "pl_counter_valid": pl_counter_valid,
            "pl_counter_warning": (
                None
                if pl_counter_valid
                else "RTL performance counters are zero or inconsistent; PL cycle-derived metrics are unavailable"
            ),
            "pl_total_cycles": [int(value) for value in pl_cycles],
            "pl_mac_cycles": [int(value) for value in pl_mac_cycles],
            "pl_stall_cycles": [int(value) for value in pl_stall_cycles],
            "pl_core_active_cycles_excluding_stalls": [
                int(value) for value in pl_compute_cycles
            ],
            "pl_total_cycles_stats": _stats(pl_cycles) if pl_counter_valid else None,
            "pl_mac_cycles_stats": _stats(pl_mac_cycles) if pl_counter_valid else None,
            "pl_stall_cycles_stats": _stats(pl_stall_cycles) if pl_counter_valid else None,
            "pl_core_active_cycles_excluding_stalls_stats": (
                _stats(pl_compute_cycles) if pl_counter_valid else None
            ),
            "pl_transaction_ms_from_cycles": pl_transaction_stats,
            "pl_core_active_ms_excluding_stalls": pl_compute_stats,
            "pl_mac_active_ms_from_cycles": pl_mac_stats,
            "pl_stall_ms_from_cycles": pl_stall_stats,
            "host_to_host_attention_ms": e2e_stats,
            "profiles": fpga_profiles,
        },
        "cpu_baseline": {
            "definition": "KV260 Cortex-A53 NumPy fp32 GQA attention; bf16 inputs; stable exact-exp softmax; no FPGA invocation",
            "wall_ms": cpu_stats,
            "cpu_clock_mhz": cpu_clock_mhz,
            "estimated_cycles": cpu_estimated_cycles,
            "estimated_cycles_stats": (
                _stats(cpu_estimated_cycles) if cpu_estimated_cycles else None
            ),
            "cycle_note": (
                "Estimated as wall_ms * recorded_cpu_clock_mhz * 1000; "
                "this is not a hardware PMU cycle counter."
            ),
        },
    }


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = [
        "case_id", "case_set", "seq_len", "causal", "q_pos_base", "kv_pos_base",
        "fpga_bit_exact", "mismatch_count", "pl_clock_mhz", "pl_cycles_median",
        "pl_mac_cycles_median", "pl_stall_cycles_median", "pl_core_active_cycles_median",
        "pl_ms_median", "pl_core_active_ms_median", "pl_mac_active_ms_median",
        "pl_stall_ms_median", "fpga_e2e_ms_median", "cpu_ms_median",
        "cpu_clock_mhz", "cpu_estimated_cycles_median",
    ]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({
                "case_id": row["case_id"],
                "case_set": row["case_set"],
                "seq_len": row["seq_len"],
                "causal": row["causal"],
                "q_pos_base": row["q_pos_base"],
                "kv_pos_base": row["kv_pos_base"],
                "fpga_bit_exact": row["correctness"]["fpga_bit_exact_expected"],
                "mismatch_count": row["correctness"]["fpga_mismatch_count"],
                "pl_clock_mhz": row["fpga"]["pl_clock_mhz"],
                "pl_cycles_median": (
                    row["fpga"]["pl_total_cycles_stats"]["median"]
                    if row["fpga"]["pl_total_cycles_stats"] is not None
                    else ""
                ),
                "pl_mac_cycles_median": (
                    row["fpga"]["pl_mac_cycles_stats"]["median"]
                    if row["fpga"]["pl_mac_cycles_stats"] is not None
                    else ""
                ),
                "pl_stall_cycles_median": (
                    row["fpga"]["pl_stall_cycles_stats"]["median"]
                    if row["fpga"]["pl_stall_cycles_stats"] is not None
                    else ""
                ),
                "pl_core_active_cycles_median": (
                    row["fpga"]["pl_core_active_cycles_excluding_stalls_stats"]["median"]
                    if row["fpga"]["pl_core_active_cycles_excluding_stalls_stats"] is not None
                    else ""
                ),
                "pl_ms_median": (
                    row["fpga"]["pl_transaction_ms_from_cycles"]["median"]
                    if row["fpga"]["pl_transaction_ms_from_cycles"] is not None
                    else ""
                ),
                "pl_core_active_ms_median": (
                    row["fpga"]["pl_core_active_ms_excluding_stalls"]["median"]
                    if row["fpga"]["pl_core_active_ms_excluding_stalls"] is not None
                    else ""
                ),
                "pl_mac_active_ms_median": (
                    row["fpga"]["pl_mac_active_ms_from_cycles"]["median"]
                    if row["fpga"]["pl_mac_active_ms_from_cycles"] is not None
                    else ""
                ),
                "pl_stall_ms_median": (
                    row["fpga"]["pl_stall_ms_from_cycles"]["median"]
                    if row["fpga"]["pl_stall_ms_from_cycles"] is not None
                    else ""
                ),
                "fpga_e2e_ms_median": row["fpga"]["host_to_host_attention_ms"]["median"],
                "cpu_ms_median": row["cpu_baseline"]["wall_ms"]["median"],
                "cpu_clock_mhz": row["cpu_baseline"]["cpu_clock_mhz"],
                "cpu_estimated_cycles_median": (
                    row["cpu_baseline"]["estimated_cycles_stats"]["median"]
                    if row["cpu_baseline"]["estimated_cycles_stats"] is not None
                    else ""
                ),
            })


def _parse_case_set(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("case set must be LABEL=DIRECTORY")
    label, directory = value.split("=", 1)
    if not label or not directory:
        raise argparse.ArgumentTypeError("case set must be LABEL=DIRECTORY")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", label) is None:
        raise argparse.ArgumentTypeError(
            "case-set label may contain only letters, digits, '.', '_' and '-'"
        )
    return label, Path(directory)


def _resolve_case_sets(values: list[tuple[str, Path]]) -> list[tuple[str, Path]]:
    labels: set[str] = set()
    resolved: list[tuple[str, Path]] = []
    for label, directory in values:
        if label in labels:
            raise ValueError(f"duplicate case-set label: {label}")
        labels.add(label)
        resolved.append((label, directory.expanduser().resolve()))
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bitstream", help="lara_attention.bit; matching .hwh must be beside it")
    parser.add_argument(
        "--case-set", action="append", type=_parse_case_set,
        required=True, metavar="LABEL=DIRECTORY",
        help="repeatable; explicitly select each test-case directory",
    )
    parser.add_argument("--output-dir", default="board_performance_results")
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument(
        "--timeout-ms",
        type=int,
        default=None,
        help="optional hardware timeout; omitted means no time limit",
    )
    parser.add_argument(
        "--lengths",
        nargs="+",
        type=int,
        default=list(REQUIRED_LENGTHS),
        help="sequence lengths to benchmark",
    )
    parser.add_argument(
        "--causal-only",
        action="store_true",
        help="benchmark only causal cases",
    )
    parser.add_argument("--cpu-core", type=int, help="pin this process to one Cortex-A53 core")
    parser.add_argument(
        "--cpu-clock-mhz",
        type=float,
        help=(
            "stable CPU clock for estimated CPU cycle reporting; "
            "default: read the pinned core's cpufreq sysfs entry"
        ),
    )
    parser.add_argument(
        "--reuse-overlay-within-case",
        action="store_true",
        help=(
            "reuse one programmed Overlay for warmups/repeats; diagnostic only, "
            "default reprograms before every FPGA sample to isolate PL state"
        ),
    )
    parser.add_argument("--list-only", action="store_true", help="validate/list the required matrix without loading FPGA")
    args = parser.parse_args()
    if args.warmup < 0 or args.repeats < 1:
        parser.error("--warmup must be >= 0 and --repeats must be >= 1")
    if args.cpu_clock_mhz is not None and args.cpu_clock_mhz <= 0:
        parser.error("--cpu-clock-mhz must be > 0")
    if any(length < 1 or length > MAX_SEQ_LEN for length in args.lengths):
        parser.error(f"all --lengths values must be in 1..{MAX_SEQ_LEN}")
    if len(set(args.lengths)) != len(args.lengths):
        parser.error("--lengths values must not contain duplicates")

    try:
        case_sets = _resolve_case_sets(args.case_set)
    except ValueError as exc:
        parser.error(str(exc))
    selected_modes = (True,) if args.causal_only else REQUIRED_MODES
    cases = discover_cases(case_sets, lengths=args.lengths, modes=selected_modes)
    for case in cases:
        print(f"FOUND {_case_id(case)}: {case.path}")
    if args.list_only:
        print(f"selected performance matrix complete: {len(cases)} cases")
        return 0
    if not args.bitstream:
        parser.error("--bitstream is required unless --list-only is used")
    if args.cpu_core is not None:
        if not hasattr(os, "sched_setaffinity"):
            raise RuntimeError("CPU affinity is unavailable on this platform")
        os.sched_setaffinity(0, {args.cpu_core})
    cpu_clock_mhz = args.cpu_clock_mhz or detect_cpu_clock_mhz(args.cpu_core)
    if cpu_clock_mhz is None:
        print(
            "WARNING: CPU clock is unavailable; estimated CPU cycles will be null. "
            "Pin a core or pass --cpu-clock-mhz.",
            flush=True,
        )
    else:
        print(f"CPU clock for estimated cycles: {cpu_clock_mhz:.6f} MHz", flush=True)

    bitstream = Path(args.bitstream).resolve()
    if not bitstream.is_file():
        raise FileNotFoundError(f"bitstream does not exist: {bitstream}")
    hwh = bitstream.with_suffix(".hwh")
    if not hwh.is_file():
        raise FileNotFoundError(f"matching HWH does not exist: {hwh}")
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    environment_before = collect_environment()

    rows: list[dict[str, Any]] = []
    benchmark_errors: list[dict[str, str]] = []
    for index, case in enumerate(cases, start=1):
        case_id = _case_id(case)
        print(f"[{index}/{len(cases)}] BENCHMARK START {case_id}", flush=True)
        try:
            if args.reuse_overlay_within_case:
                print(f"  Loading shared Overlay: {bitstream}", flush=True)
                with AttentionAccelerator(str(bitstream)) as accel:
                    if not accel.hw_ready:
                        raise RuntimeError(
                            "PYNQ hardware is unavailable; run this benchmark on the KV260"
                        )
                    print("  Shared Overlay ready", flush=True)
                    row = benchmark_case(
                        accel, case, warmup=args.warmup,
                        repeats=args.repeats, timeout_ms=args.timeout_ms,
                        cpu_clock_mhz=cpu_clock_mhz,
                    )
            else:
                print("  Fresh-Overlay isolation enabled for every FPGA sample", flush=True)
                row = benchmark_case(
                    FreshOverlayRunner(bitstream), case, warmup=args.warmup,
                    repeats=args.repeats, timeout_ms=args.timeout_ms,
                    cpu_clock_mhz=cpu_clock_mhz,
                )
        except Exception as exc:
            benchmark_errors.append({
                "case_id": _case_id(case),
                "exception": type(exc).__name__,
                "error": str(exc),
            })
            print(f"  ERROR {type(exc).__name__}: {exc}", flush=True)
            break
        rows.append(row)
        status = "PASS" if row["correctness"]["fpga_bit_exact_expected"] else "FAIL"
        pl_stats = row["fpga"]["pl_transaction_ms_from_cycles"]
        pl_text = "N/A" if pl_stats is None else f"{pl_stats['median']:.6f} ms"
        pl_compute_stats = row["fpga"]["pl_core_active_ms_excluding_stalls"]
        pl_compute_text = (
            "N/A"
            if pl_compute_stats is None
            else f"{pl_compute_stats['median']:.6f} ms"
        )
        cpu_cycles_stats = row["cpu_baseline"]["estimated_cycles_stats"]
        cpu_cycles_text = (
            "N/A"
            if cpu_cycles_stats is None
            else f"{cpu_cycles_stats['median']:.0f} estimated cycles"
        )
        print(
            f"[{index}/{len(cases)}] BENCHMARK {status} {case_id}: "
            f"PL_TX={pl_text} PL_ACTIVE={pl_compute_text} "
            f"E2E={row['fpga']['host_to_host_attention_ms']['median']:.6f} ms "
            f"CPU={row['cpu_baseline']['wall_ms']['median']:.6f} ms "
            f"CPU_CYCLES={cpu_cycles_text}",
            flush=True,
        )

    report = {
        "schema": "lara-board-measurements-v3.0",
        "methodology": {
            "official_status": (
                "FPT 2026 Track B requests performance, architecture optimization, and scalability, "
                "but the official page and Track-B guide do not prescribe a baseline, workload matrix, "
                "repeat count, clock, or performance formula as of 2026-08-06."
            ),
            "official_sources": [OFFICIAL_PAGE, OFFICIAL_GUIDE],
            "fpga_pl_transaction_time": "retained RTL total cycles / configured PL frequency (71.427856 MHz); includes explicitly counted external stalls",
            "fpga_pl_core_active_time": "(retained RTL total cycles - retained external stall cycles) / configured PL frequency; controller-active time, not a claim of pure MAC-only time",
            "fpga_pl_mac_active_time": "retained RTL MAC-active cycles / configured PL frequency",
            "fpga_host_to_host_time": "driver attention wall time, including request service and DMA; excludes Overlay programming and PYNQ buffer allocation",
            "cpu_primary_time": "perf_counter_ns wall time on the same KV260; independent of CPU/PL clock domains",
            "state_isolation": (
                "one Overlay is reused within each case because --reuse-overlay-within-case was requested"
                if args.reuse_overlay_within_case
                else "Overlay is reprogrammed before every FPGA warmup and measured sample; programming and buffer allocation are outside the recorded case latency"
            ),
            "statistics": "one warmup by default; min/median/p95/max over five measured runs",
            "cpu_cycle_accounting": (
                "CPU cycles are estimated as measured wall time multiplied by the recorded stable "
                "CPU MHz; no per-case PMU hardware cycle counter is used."
            ),
            "comparison_policy": (
                "The report contains independent FPGA and CPU measurements and bit-exact correctness. "
                "It intentionally does not calculate speedup, relative efficiency, or an automatic "
                "winner."
            ),
            "selected_lengths": args.lengths,
            "selected_modes": ["causal"] if args.causal_only else ["causal", "noncausal"],
            "selected_case_sets": {
                label: str(directory) for label, directory in case_sets
            },
        },
        "artifacts": {
            "bitstream": str(bitstream),
            "bitstream_sha256": _sha256(bitstream),
            "hwh": str(hwh),
            "hwh_sha256": _sha256(hwh),
        },
        "environment_before": environment_before,
        "environment_after": collect_environment(),
        "results": rows,
        "benchmark_errors": benchmark_errors,
    }
    json_path = output_dir / "performance.json"
    csv_path = output_dir / "performance.csv"
    json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    _write_csv(csv_path, rows)
    passed = sum(row["correctness"]["fpga_bit_exact_expected"] for row in rows)
    print(f"bit-exact matrix: {passed}/{len(cases)} PASS")
    if benchmark_errors:
        print(f"benchmark stopped after error: {benchmark_errors[0]}")
    print(f"JSON: {json_path.resolve()}")
    print(f"CSV:  {csv_path.resolve()}")
    return 0 if passed == len(cases) and not benchmark_errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
