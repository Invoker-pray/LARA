#!/usr/bin/env python3
"""Extract reproducible Vivado signoff and deployment metrics.

The generated JSON/CSV files belong under vivado_proj (ignored by Git).  The
script deliberately parses reports instead of trusting a stale bitstream name.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_value(root: Path, *args: str) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), *args], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def parse_timing(path: Path) -> dict[str, Any]:
    lines = text(path).splitlines()
    result: dict[str, Any] = {}
    for line in lines:
        if line.startswith("| Tool Version"):
            result["tool_version"] = line.split(":", 1)[1].strip()
        elif line.startswith("| Date"):
            result["report_date"] = line.split(":", 1)[1].strip()
        elif line.startswith("| Device"):
            result["device"] = line.split(":", 1)[1].strip()

    start = next(
        (index for index, line in enumerate(lines) if "Design Timing Summary" in line),
        0,
    )
    number_row = re.compile(
        r"^\s*([+-]?\d+(?:\.\d+)?)\s+"
        r"([+-]?\d+(?:\.\d+)?)\s+(\d+)\s+(\d+)\s+"
        r"([+-]?\d+(?:\.\d+)?)\s+"
        r"([+-]?\d+(?:\.\d+)?)\s+(\d+)\s+(\d+)"
    )
    for line in lines[start : start + 45]:
        match = number_row.match(line)
        if match:
            values = match.groups()
            result.update(
                {
                    "wns_ns": float(values[0]),
                    "tns_ns": float(values[1]),
                    "setup_failing_endpoints": int(values[2]),
                    "setup_total_endpoints": int(values[3]),
                    "whs_ns": float(values[4]),
                    "ths_ns": float(values[5]),
                    "hold_failing_endpoints": int(values[6]),
                    "hold_total_endpoints": int(values[7]),
                }
            )
            break
    return result


def parse_route(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    patterns = {
        "logical_nets": r"# of logical nets\.*\s*:\s*(\d+)",
        "routable_nets": r"# of routable nets\.*\s*:\s*(\d+)",
        "fully_routed_nets": r"# of fully routed nets\.*\s*:\s*(\d+)",
        "routing_errors": r"# of nets with routing errors\.*\s*:\s*(\d+)",
    }
    report = text(path)
    for key, pattern in patterns.items():
        match = re.search(pattern, report)
        if match:
            result[key] = int(match.group(1))
    return result


def parse_utilization(path: Path) -> dict[str, Any]:
    lines = text(path).splitlines()
    header_index = next(
        (index for index, line in enumerate(lines) if "Total LUTs" in line and "DSP Blocks" in line),
        None,
    )
    if header_index is None:
        return {}
    headers = [field.strip() for field in lines[header_index].strip("|").split("|")]
    for line in lines[header_index + 1 :]:
        if "attn_soc_wrapper" not in line or line.startswith("+"):
            continue
        fields = [field.strip() for field in line.strip("|").split("|")]
        if len(fields) != len(headers):
            continue
        row = dict(zip(headers, fields))
        result: dict[str, Any] = {}
        for source, target in (
            ("Total LUTs", "luts"),
            ("FFs", "ffs"),
            ("RAMB36", "ramb36"),
            ("RAMB18", "ramb18"),
            ("URAM", "uram"),
            ("DSP Blocks", "dsp"),
        ):
            if source in row:
                result[target] = int(row[source].replace(",", ""))
        if "ramb36" in result and "ramb18" in result:
            result["bram36_equivalent"] = result["ramb36"] + (result["ramb18"] // 2)
        return result
    return {}


def parse_hwh(path: Path) -> dict[str, Any]:
    report = text(path)
    match = re.search(r'C_SG_LENGTH_WIDTH" VALUE="(\d+)"', report)
    return {"c_sg_length_width": int(match.group(1))} if match else {}


def collect(root: Path) -> dict[str, Any]:
    report_dir = root / "vivado_proj" / "reports"
    deploy_dir = root / "vivado_proj" / "deploy"
    hwh = deploy_dir / "lara_attention.hwh"
    result: dict[str, Any] = {
        "git_commit": git_value(root, "rev-parse", "HEAD"),
        "git_branch": git_value(root, "branch", "--show-current"),
        "timing": parse_timing(report_dir / "post_route_timing_summary.rpt"),
        "route": parse_route(report_dir / "post_route_status.rpt"),
        "utilization": parse_utilization(report_dir / "post_route_utilization.rpt"),
        "hwh": parse_hwh(hwh),
        "artifacts": {
            name: sha256(deploy_dir / name)
            for name in ("lara_attention.bit", "lara_attention.hwh", "lara_attention.xsa")
        },
    }
    result["reports"] = {
        name: sha256(report_dir / name)
        for name in (
            "post_route_timing_summary.rpt",
            "post_route_status.rpt",
            "post_route_utilization.rpt",
            "post_route_drc.rpt",
        )
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("vivado_proj/optimization_baseline/v2.4_signoff.json"),
    )
    args = parser.parse_args()
    root = args.root.resolve()
    output = args.out if args.out.is_absolute() else root / args.out
    output.parent.mkdir(parents=True, exist_ok=True)
    metrics = collect(root)
    output.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    flat: dict[str, Any] = {"git_commit": metrics.get("git_commit"), "git_branch": metrics.get("git_branch")}
    for section in ("timing", "route", "utilization", "hwh"):
        flat.update({f"{section}.{key}": value for key, value in metrics[section].items()})
    flat.update({f"artifact.{key}": value for key, value in metrics["artifacts"].items()})
    csv_path = output.with_suffix(".csv")
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=sorted(flat))
        writer.writeheader()
        writer.writerow(flat)
    print(f"wrote {output}")
    print(f"wrote {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
