#!/usr/bin/env python3
"""Run all LARA KV260 functional and CPU/FPGA performance matrices."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED_LENGTHS = (1, 16, 32, 64, 128)
CASE_SETS = (
    ("q3kv3", "board_cases_rtl_contract_v2.6_fixed"),
    ("q31kv7", "board_cases_rtl_contract_v2.6_q31_kv7"),
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def _require_empty_output(path: Path) -> None:
    if path.exists() and any(path.iterdir()):
        raise FileExistsError(
            f"result directory is not empty: {path}; choose a new --output-dir"
        )
    path.mkdir(parents=True, exist_ok=True)


def _run_logged(
    command: list[str],
    log_path: Path,
    *,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    print("RUN:", " ".join(command), flush=True)
    started_utc = datetime.now(timezone.utc).isoformat()
    started = time.perf_counter()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
            start_new_session=True,
        )
        try:
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
            return_code = process.wait()
        except BaseException:
            # The stage runs in its own process group.  Reap the complete
            # board-test tree so Ctrl-C cannot leave a Python/PYNQ process
            # servicing DMA or retaining ownership of the programmed PL.
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.wait()
            raise
    elapsed = time.perf_counter() - started
    result = {
        "command": command,
        "log": str(log_path),
        "started_utc": started_utc,
        "elapsed_seconds": elapsed,
        "return_code": return_code,
        "status": "PASS" if return_code == 0 else "FAIL",
    }
    print(
        f"STAGE {result['status']}: return_code={return_code} "
        f"elapsed={elapsed:.3f}s log={log_path}",
        flush=True,
    )
    return result


def _functional_summary(path: Path, expected_total: int = 10) -> dict[str, Any]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rows, list):
        raise ValueError(f"functional summary is not a list: {path}")
    passed = sum(row.get("status") == "PASS" for row in rows)
    return {
        "path": str(path),
        "passed": passed,
        "total": len(rows),
        "all_passed": passed == len(rows) == expected_total,
    }


def _performance_summary(path: Path, expected_total: int = 20) -> dict[str, Any]:
    report = json.loads(path.read_text(encoding="utf-8"))
    rows = report.get("results", [])
    errors = report.get("benchmark_errors", [])
    passed = sum(
        row.get("correctness", {}).get("fpga_bit_exact_expected") is True
        for row in rows
    )
    return {
        "json": str(path),
        "csv": str(path.with_name("performance.csv")),
        "passed": passed,
        "total": len(rows),
        "benchmark_errors": errors,
        "all_passed": passed == len(rows) == expected_total and not errors,
    }


def _copy_provenance(root: Path, result_dir: Path, bitstream: Path) -> dict[str, Any]:
    provenance = result_dir / "provenance"
    provenance.mkdir(parents=True, exist_ok=True)
    names = (
        "LARA_SHA256SUMS",
        "board_environment.txt",
        "board_environment.json",
        "deployed_hardware_sha256.txt",
        "attn_driver.py",
        "clear_pynq_cache.py",
        "board_test.py",
        "board_matrix.py",
        "board_performance.py",
        "run_board_full_validation.py",
    )
    copied: list[dict[str, Any]] = []
    for name in names:
        source = root / name
        if not source.is_file():
            continue
        destination = provenance / name
        shutil.copy2(source, destination)
        copied.append({
            "source": str(source),
            "copy": str(destination),
            "sha256": _sha256(destination),
        })
    artifacts: dict[str, Any] = {}
    for path in (bitstream, bitstream.with_suffix(".hwh"), bitstream.with_suffix(".xsa")):
        artifacts[path.name] = {
            "path": str(path),
            "size_bytes": path.stat().st_size,
            "sha256": _sha256(path),
        }
    return {"files": copied, "deployment_artifacts": artifacts}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bitstream", default="./lara_attention.bit")
    parser.add_argument("--output-dir", default="./board_full_results")
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument(
        "--cpu-threads",
        nargs="+",
        type=int,
        default=[1],
        help="CPU baseline thread counts; use '1 4' to archive both baselines",
    )
    parser.add_argument(
        "--cpu-core",
        type=int,
        help="optionally pin the performance process to one Cortex-A53 core",
    )
    parser.add_argument(
        "--allow-missing-init-report",
        action="store_true",
        help="do not require board_environment.json from clear_pynq_cache.py",
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--quick-q31kv7",
        action="store_true",
        help="run only q31/kv7 L1 causal and L128 causal (two cases)",
    )
    mode_group.add_argument(
        "--extended-q31kv7-l512",
        action="store_true",
        help="run only the maximum supported q31/kv7 L512 causal case",
    )
    args = parser.parse_args()
    if args.warmup < 0 or args.repeats < 1:
        parser.error("--warmup must be >= 0 and --repeats must be >= 1")
    if any(threads < 1 for threads in args.cpu_threads):
        parser.error("all --cpu-threads values must be >= 1")
    if len(set(args.cpu_threads)) != len(args.cpu_threads):
        parser.error("--cpu-threads values must not contain duplicates")
    if args.cpu_core is not None and args.cpu_core < 0:
        parser.error("--cpu-core must be >= 0")

    root = Path.cwd().resolve()
    bitstream = Path(args.bitstream).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    if args.extended_q31kv7_l512:
        selected_case_sets = (CASE_SETS[1],)
        selected_lengths = (512,)
        causal_only = True
    elif args.quick_q31kv7:
        selected_case_sets = (CASE_SETS[1],)
        selected_lengths = (1, 128)
        causal_only = True
    else:
        selected_case_sets = CASE_SETS
        selected_lengths = REQUIRED_LENGTHS
        causal_only = False
    expected_functional_total = len(selected_lengths) * (1 if causal_only else 2)
    expected_performance_total = expected_functional_total * len(selected_case_sets)
    required_files = [
        bitstream,
        bitstream.with_suffix(".hwh"),
        bitstream.with_suffix(".xsa"),
        root / "attn_driver.py",
        root / "board_matrix.py",
        root / "board_performance.py",
    ]
    required_files.extend(root / directory for _, directory in selected_case_sets)
    missing = [str(path) for path in required_files if not path.exists()]
    if missing:
        raise FileNotFoundError("required board inputs are missing: " + ", ".join(missing))

    init_path = root / "board_environment.json"
    init_report: dict[str, Any] | None = None
    if init_path.is_file():
        init_report = json.loads(init_path.read_text(encoding="utf-8"))
        if init_report.get("overall_status") != "PASS":
            raise RuntimeError(
                f"board initialization did not pass: {init_path}; "
                f"issues={init_report.get('issues')}"
            )
    elif not args.allow_missing_init_report:
        raise FileNotFoundError(
            "board_environment.json is missing; first run: "
            "python3 clear_pynq_cache.py --bitstream ./lara_attention.bit"
        )

    _require_empty_output(output_dir)
    manifest_path = output_dir / "run_manifest.json"
    consolidated_path = output_dir / "consolidated_results.json"
    manifest: dict[str, Any] = {
        "schema": "lara-kv260-full-validation-v1",
        "status": "RUNNING",
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "working_directory": str(root),
        "output_directory": str(output_dir),
        "configuration": {
            "bitstream": str(bitstream),
            "lengths": list(selected_lengths),
            "case_sets": dict(selected_case_sets),
            "causal_only": causal_only,
            "quick_q31kv7": args.quick_q31kv7,
            "extended_q31kv7_l512": args.extended_q31kv7_l512,
            "warmup": args.warmup,
            "repeats": args.repeats,
            "cpu_threads": args.cpu_threads,
            "cpu_core": args.cpu_core,
        },
        "initialization_report": init_report,
        "provenance": _copy_provenance(root, output_dir, bitstream),
        "stages": [],
    }
    _write_json(manifest_path, manifest)

    python = sys.executable
    try:
        for label, case_directory in selected_case_sets:
            result_path = output_dir / "functional" / label
            log_path = output_dir / "logs" / f"functional_{label}.log"
            command = [
                python,
                str(root / "board_matrix.py"),
                "--bitstream", str(bitstream),
                "--cases", str(root / case_directory),
                "--output-dir", str(result_path),
                "--lengths", *(str(length) for length in selected_lengths),
            ]
            if causal_only:
                command.append("--causal-only")
            stage = _run_logged(command, log_path)
            stage.update({"kind": "functional", "case_set": label})
            manifest["stages"].append(stage)
            _write_json(manifest_path, manifest)
            if stage["return_code"] != 0:
                raise RuntimeError(f"functional matrix failed: {label}")

        for threads in args.cpu_threads:
            result_path = output_dir / "performance" / f"cpu{threads}"
            log_path = output_dir / "logs" / f"performance_cpu{threads}.log"
            command = [
                python,
                str(root / "board_performance.py"),
                "--bitstream", str(bitstream),
                "--warmup", str(args.warmup),
                "--repeats", str(args.repeats),
                "--output-dir", str(result_path),
                "--lengths", *(str(length) for length in selected_lengths),
            ]
            for label, case_directory in selected_case_sets:
                command.extend(["--case-set", f"{label}={root / case_directory}"])
            if causal_only:
                command.append("--causal-only")
            if args.cpu_core is not None:
                command.extend(["--cpu-core", str(args.cpu_core)])
            environment = os.environ.copy()
            environment["LARA_CPU_THREADS"] = str(threads)
            stage = _run_logged(command, log_path, env=environment)
            stage.update({"kind": "performance", "cpu_threads": threads})
            manifest["stages"].append(stage)
            _write_json(manifest_path, manifest)
            if stage["return_code"] != 0:
                raise RuntimeError(f"performance matrix failed: CPU threads={threads}")

        functional = {
            label: _functional_summary(
                output_dir / "functional" / label / "summary.json",
                expected_total=expected_functional_total,
            )
            for label, _ in selected_case_sets
        }
        performance = {
            f"cpu{threads}": _performance_summary(
                output_dir / "performance" / f"cpu{threads}" / "performance.json",
                expected_total=expected_performance_total,
            )
            for threads in args.cpu_threads
        }
        all_passed = (
            all(item["all_passed"] for item in functional.values())
            and all(item["all_passed"] for item in performance.values())
        )
        consolidated = {
            "overall_status": "PASS" if all_passed else "FAIL",
            "functional": functional,
            "performance": performance,
            "run_manifest": str(manifest_path),
        }
        _write_json(consolidated_path, consolidated)
        manifest["status"] = consolidated["overall_status"]
    except KeyboardInterrupt:
        manifest["status"] = "INTERRUPTED"
        manifest["error"] = "KeyboardInterrupt"
    except Exception as exc:
        manifest["status"] = "FAIL"
        manifest["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        manifest["ended_utc"] = datetime.now(timezone.utc).isoformat()
        _write_json(manifest_path, manifest)

    print(f"FULL VALIDATION STATUS: {manifest['status']}")
    print(f"Result directory: {output_dir}")
    print(f"Run manifest: {manifest_path}")
    if consolidated_path.is_file():
        print(f"Consolidated results: {consolidated_path}")
    return 0 if manifest["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
