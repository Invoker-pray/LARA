#!/usr/bin/env python3
"""Run a directory of exact-bf16 KV260 cases and archive profiles."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np

# Support execution from the repository root and from `sw/`.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from attn_driver import AttentionAccelerator


def _scalar(data: np.lib.npyio.NpzFile, name: str, default: int) -> int:
    value = data.get(name)
    return default if value is None else int(np.asarray(value).item())


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _case_sort_key(path: Path) -> tuple[int, int, str]:
    with np.load(path) as data:
        q = np.asarray(data["q_heads"])
        seq_len = _scalar(data, "seq_len", int(q.shape[1]))
        causal = bool(_scalar(data, "causal", 1))
    return seq_len, 0 if causal else 1, path.name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bitstream", required=True)
    parser.add_argument("--cases", required=True, help="directory created by generate_board_cases.py")
    parser.add_argument("--output-dir", default="board_results_v2.6")
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
        help="optional sequence-length filter, for example: 1 16 32 64 128",
    )
    parser.add_argument(
        "--causal-only",
        action="store_true",
        help="run only causal cases after applying the length filter",
    )
    parser.add_argument(
        "--environment-json",
        help="optional JSON file with board/image/PYNQ/temperature metadata",
    )
    args = parser.parse_args()

    bitstream_path = Path(args.bitstream).resolve()
    if not bitstream_path.is_file():
        raise FileNotFoundError(f"bitstream does not exist: {bitstream_path}")
    case_dir = Path(args.cases)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    input_archive = output_dir / "inputs"
    input_archive.mkdir(exist_ok=True)
    case_paths = list(case_dir.glob("case_*.npz"))
    if not case_paths:
        raise FileNotFoundError(f"no case_*.npz files found in {case_dir}")
    if args.lengths or args.causal_only:
        requested_lengths = set(args.lengths) if args.lengths else None
        filtered_paths: list[Path] = []
        for case_path in case_paths:
            with np.load(case_path) as data:
                q = np.asarray(data["q_heads"])
                seq_len = _scalar(data, "seq_len", int(q.shape[1]))
                causal = bool(_scalar(data, "causal", 1))
            if (
                (requested_lengths is None or seq_len in requested_lengths)
                and (not args.causal_only or causal)
            ):
                filtered_paths.append(case_path)
        case_paths = filtered_paths
        if not case_paths:
            raise FileNotFoundError(
                f"no case_*.npz files in {case_dir} match the requested filters"
            )
    case_paths.sort(key=_case_sort_key)

    summary: list[dict[str, object]] = []
    print(f"Selected FPGA functional cases: {len(case_paths)}", flush=True)
    for index, case_path in enumerate(case_paths, start=1):
        print(
            f"[{index}/{len(case_paths)}] FPGA FUNCTIONAL START {case_path.name}",
            flush=True,
        )
        row: dict[str, object] = {"case": case_path.name, "status": "FAIL"}
        archived_case = input_archive / case_path.name
        shutil.copy2(case_path, archived_case)
        row["input"] = str(archived_case)
        accel: AttentionAccelerator | None = None
        try:
            print(f"  Loading overlay: {bitstream_path}", flush=True)
            accel = AttentionAccelerator(str(bitstream_path))
            print("  Overlay ready", flush=True)
            try:
                with np.load(case_path) as data:
                    q = np.asarray(data["q_heads"], dtype=np.uint16)
                    k = np.asarray(data["k_heads"], dtype=np.uint16)
                    v = np.asarray(data["v_heads"], dtype=np.uint16)
                    expected = np.asarray(data["expected_o"], dtype=np.uint16)
                    seq_len = _scalar(data, "seq_len", int(q.shape[1]))
                    causal = bool(_scalar(data, "causal", 1))
                    q_pos_base = _scalar(data, "q_pos_base", 0)
                    kv_pos_base = _scalar(data, "kv_pos_base", 0)

                actual = accel.run_attention(
                    q,
                    k,
                    v,
                    seq_len=seq_len,
                    q_pos_base=q_pos_base,
                    kv_pos_base=kv_pos_base,
                    causal=causal,
                    timeout_ms=args.timeout_ms,
                )
                actual_path = output_dir / f"{case_path.stem}_actual.npz"
                np.savez_compressed(actual_path, o_heads=actual)
                profile_path = output_dir / f"{case_path.stem}_profile.json"
                accel.save_last_profile(profile_path)
                row.update({
                    "actual": str(actual_path),
                    "profile": str(profile_path),
                    "perf": accel.read_perf(),
                })
                mismatch = np.argwhere(actual != expected)
                if mismatch.size:
                    first = tuple(int(value) for value in mismatch[0])
                    raise RuntimeError(
                        f"bit mismatch at {first}: "
                        f"got=0x{int(actual[first]):04x} "
                        f"expected=0x{int(expected[first]):04x}; "
                        f"mismatches={len(mismatch)}"
                    )

                row.update({
                    "status": "PASS",
                    "seq_len": seq_len,
                    "causal": causal,
                    "q_pos_base": q_pos_base,
                    "kv_pos_base": kv_pos_base,
                })
                print(f"[{index}/{len(case_paths)}] FPGA FUNCTIONAL PASS {case_path.name}", flush=True)
            finally:
                accel.close()
        except Exception as exc:  # Keep the summary usable after the first failure.
            if accel is not None:
                if accel.last_profile is not None:
                    profile_path = output_dir / f"{case_path.stem}_profile.json"
                    try:
                        accel.save_last_profile(profile_path)
                        row["profile"] = str(profile_path)
                    except RuntimeError:
                        pass
                accel.close()
            row["error"] = str(exc)
            print(f"[{index}/{len(case_paths)}] FPGA FUNCTIONAL FAIL {case_path.name}: {exc}", flush=True)
        summary.append(row)

    summary_path = output_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    environment: dict[str, object] = {}
    if args.environment_json:
        with Path(args.environment_json).open(encoding="utf-8") as stream:
            loaded = json.load(stream)
        if not isinstance(loaded, dict):
            raise ValueError("--environment-json must contain a JSON object")
        environment = loaded
    manifest = {
        "bitstream": str(bitstream_path),
        "bitstream_sha256": _sha256(bitstream_path),
        "cases_dir": str(case_dir.resolve()),
        "length_filter": sorted(set(args.lengths)) if args.lengths else None,
        "causal_filter": True if args.causal_only else None,
        "results_dir": str(output_dir.resolve()),
        "input_archive": str(input_archive.resolve()),
        "environment": environment,
        "cases": summary,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    passed = sum(row["status"] == "PASS" for row in summary)
    print(f"board matrix: {passed}/{len(summary)} PASS", flush=True)
    print(f"summary: {summary_path.resolve()}", flush=True)
    print(f"manifest: {manifest_path.resolve()}", flush=True)
    return 0 if passed == len(summary) else 1


if __name__ == "__main__":
    raise SystemExit(main())
