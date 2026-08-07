#!/usr/bin/env python3
"""Initialize and audit the KV260 PYNQ environment before LARA board tests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE_FILE = "global_pl_state.json"
METADATA_FILE = "_current_metadata.pkl"


def inspect_cache(state_dir: Path, expected_bitstream: Path | None) -> tuple[bool, str]:
    """Return whether the two-file PYNQ cache is stale and explain why."""
    state_path = state_dir / STATE_FILE
    metadata_path = state_dir / METADATA_FILE
    if not state_path.exists():
        if metadata_path.exists():
            return True, f"orphaned metadata exists without {STATE_FILE}"
        return False, "no PYNQ PL cache is present"

    try:
        state: dict[str, Any] = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return True, f"cannot read {STATE_FILE}: {exc}"

    cached_name = state.get("bitfile_name")
    if not isinstance(cached_name, str) or not cached_name:
        return True, f"{STATE_FILE} has no valid bitfile_name"
    cached_bitstream = Path(cached_name).expanduser().resolve()
    if not cached_bitstream.is_file():
        return True, f"cached bitstream no longer exists: {cached_bitstream}"
    if expected_bitstream is not None and cached_bitstream != expected_bitstream:
        return True, (
            "cached bitstream differs from requested deployment: "
            f"{cached_bitstream} != {expected_bitstream}"
        )
    if not metadata_path.is_file():
        return True, f"{METADATA_FILE} is missing for the cached bitstream"
    return False, f"cache is valid for {cached_bitstream}"


def clear_cache(state_dir: Path, *, dry_run: bool = False) -> list[Path]:
    """Remove only PYNQ's global PL state and corresponding parser pickle."""
    removed: list[Path] = []
    for name in (STATE_FILE, METADATA_FILE):
        path = state_dir / name
        if not path.exists():
            continue
        print(f"{'Would remove' if dry_run else 'Removing'}: {path}")
        if not dry_run:
            try:
                path.unlink()
            except PermissionError as exc:
                raise PermissionError(
                    f"cannot remove {path}; run this script as root or with sudo"
                ) from exc
        removed.append(path)
    return removed


def xbutil_device_ready(output: str) -> bool:
    """Recognize both legacy and table-form `xbutil examine` ready output."""
    if re.search(r"Device Ready\s*:\s*Yes\b", output, flags=re.IGNORECASE):
        return True
    return bool(re.search(r"^\s*\[[^]]+\].*\bYes\s*$", output, flags=re.MULTILINE))


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _os_release() -> dict[str, str]:
    values: dict[str, str] = {}
    path = Path("/etc/os-release")
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values


def _run(command: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return subprocess.CompletedProcess(command, 124, output + f"\nTimed out after {timeout}s\n")


def _render_text(report: dict[str, Any]) -> str:
    lines = [
        "LARA KV260 board initialization report",
        f"overall_status: {report['overall_status']}",
        f"timestamp_utc: {report['timestamp_utc']}",
        f"hostname: {report['system']['hostname']}",
        f"platform: {report['system']['platform']}",
        f"python: {report['software'].get('python')}",
        f"numpy: {report['software'].get('numpy')}",
        f"pynq: {report['software'].get('pynq_path')}",
        f"cache_status: {report['pynq_cache'].get('status')}",
        f"cache_reason: {report['pynq_cache'].get('reason')}",
        f"cache_removed: {report['pynq_cache'].get('removed')}",
        f"dtbo_status: {report['dtbo'].get('status')}",
        f"xbutil_device_ready: {report['xrt'].get('device_ready')}",
        "",
        "deployment_artifacts:",
    ]
    for name, details in report["deployment_artifacts"].items():
        lines.append(f"  {name}: {details}")
    lines.extend(["", "issues:"])
    if report["issues"]:
        lines.extend(f"  - {issue}" for issue in report["issues"])
    else:
        lines.append("  none")
    lines.extend(["", "xbutil_examine:", report["xrt"].get("output", "")])
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bitstream",
        type=Path,
        help="deployed .bit path; also checks matching .hwh and .xsa",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="clear both PYNQ cache files even when the cached deployment is valid",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="inspect everything but do not delete cache or insert DTBO",
    )
    parser.add_argument(
        "--skip-dtbo",
        action="store_true",
        help="do not insert pynq.dtbo; still require xbutil device ready",
    )
    parser.add_argument(
        "--environment-output",
        type=Path,
        default=Path("board_environment.txt"),
        help="human-readable report path",
    )
    parser.add_argument(
        "--environment-json",
        type=Path,
        default=Path("board_environment.json"),
        help="structured report path",
    )
    parser.add_argument(
        "--hardware-sha256-output",
        type=Path,
        default=Path("deployed_hardware_sha256.txt"),
        help="deployment SHA-256 manifest path",
    )
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    issues: list[str] = []
    expected: Path | None = None
    artifacts: dict[str, dict[str, Any]] = {}
    hardware_manifest: list[str] = []
    if args.bitstream is not None:
        expected = args.bitstream.expanduser().resolve()
        for path in (expected, expected.with_suffix(".hwh"), expected.with_suffix(".xsa")):
            details: dict[str, Any] = {"path": str(path), "exists": path.is_file()}
            if path.is_file():
                details["size_bytes"] = path.stat().st_size
                details["sha256"] = _sha256(path)
                hardware_manifest.append(f"{details['sha256']}  {path.name}")
            else:
                issues.append(f"deployment artifact is missing: {path}")
            artifacts[path.suffix.lstrip(".") or path.name] = details
    else:
        issues.append("--bitstream was not provided; deployment artifacts were not verified")

    software: dict[str, Any] = {"python": platform.python_version()}
    pynq_state_dir: Path | None = None
    try:
        import numpy  # type: ignore

        software["numpy"] = numpy.__version__
        if numpy.__version__ != "1.26.4":
            issues.append(f"unexpected NumPy version: {numpy.__version__} != 1.26.4")
    except ImportError as exc:
        issues.append(f"NumPy import failed: {exc}")

    try:
        import pynq  # type: ignore
        import pynq.pl_server.global_state as global_state  # type: ignore
        from pynq import Overlay, allocate  # type: ignore  # noqa: F401

        software["pynq_path"] = str(Path(pynq.__file__).resolve())
        software["overlay_allocate_import"] = True
        pynq_state_dir = Path(global_state.__file__).resolve().parent
    except ImportError as exc:
        software["overlay_allocate_import"] = False
        issues.append(
            "PYNQ import failed; source /etc/profile.d/pynq_venv.sh first: " + str(exc)
        )

    cache_report: dict[str, Any] = {
        "directory": str(pynq_state_dir) if pynq_state_dir else None,
        "status": "NOT_CHECKED",
        "reason": None,
        "removed": [],
    }
    if pynq_state_dir is not None:
        stale, reason = inspect_cache(pynq_state_dir, expected)
        cache_report.update({"status": "STALE" if stale else "CURRENT", "reason": reason})
        print(f"PYNQ cache directory: {pynq_state_dir}")
        print(f"Cache status: {'STALE' if stale else 'CURRENT'} - {reason}")
        if stale or args.force:
            try:
                removed = clear_cache(pynq_state_dir, dry_run=args.dry_run)
                cache_report["removed"] = [str(path) for path in removed]
                if removed and not args.dry_run:
                    print(f"PYNQ stale cache cleared: {len(removed)} file(s) removed.")
            except (OSError, PermissionError) as exc:
                issues.append(str(exc))
        else:
            print("No cache files removed.")

    dtbo_script = Path(sys.prefix) / "pynq-dts/insert_dtbo.py"
    dtbo_sysfs = Path("/sys/kernel/config/device-tree/overlays/pynq")
    dtbo_report: dict[str, Any] = {
        "script": str(dtbo_script),
        "sysfs": str(dtbo_sysfs),
        "status": "NOT_RUN",
        "output": "",
    }
    if args.skip_dtbo:
        dtbo_report["status"] = "SKIPPED"
    elif dtbo_sysfs.exists():
        dtbo_report["status"] = "ALREADY_PRESENT"
    elif args.dry_run:
        dtbo_report["status"] = "WOULD_INSERT"
    elif os.geteuid() != 0:
        dtbo_report["status"] = "FAILED"
        issues.append("DTBO insertion requires root; run with sudo -i")
    elif not dtbo_script.is_file():
        dtbo_report["status"] = "FAILED"
        issues.append(f"DTBO insertion script is missing: {dtbo_script}")
    else:
        completed = _run([sys.executable, str(dtbo_script)])
        dtbo_report["output"] = completed.stdout
        if completed.returncode == 0 and dtbo_sysfs.exists():
            dtbo_report["status"] = "INSERTED"
        else:
            dtbo_report["status"] = "FAILED"
            issues.append(
                f"DTBO insertion failed with exit code {completed.returncode}: "
                f"{completed.stdout.strip()}"
            )

    xrt_report: dict[str, Any] = {
        "command": None,
        "device_ready": False,
        "is_kv260": False,
        "output": "",
    }
    xbutil = shutil.which("xbutil")
    if xbutil is None:
        issues.append("xbutil is not available in PATH")
    else:
        completed = _run([xbutil, "examine"])
        xrt_report.update({
            "command": f"{xbutil} examine",
            "exit_code": completed.returncode,
            "output": completed.stdout,
            "device_ready": completed.returncode == 0 and xbutil_device_ready(completed.stdout),
            "is_kv260": bool(re.search(r"\bKV260\b", completed.stdout, re.IGNORECASE)),
        })
        if not xrt_report["device_ready"]:
            issues.append("xbutil examine did not report a ready KV260 device")
        if not xrt_report["is_kv260"]:
            issues.append("xbutil examine did not identify the target as KV260")

    report: dict[str, Any] = {
        "schema": "lara-kv260-board-init-v1",
        "overall_status": "PASS" if not issues else "FAIL",
        "timestamp_utc": now.isoformat(),
        "system": {
            "hostname": platform.node(),
            "platform": platform.platform(),
            "uname": list(platform.uname()),
            "os_release": _os_release(),
            "euid": os.geteuid(),
        },
        "software": software,
        "pynq_cache": cache_report,
        "dtbo": dtbo_report,
        "xrt": xrt_report,
        "deployment_artifacts": artifacts,
        "issues": issues,
    }
    text_report = _render_text(report)
    args.environment_output.write_text(text_report, encoding="utf-8")
    args.environment_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    args.hardware_sha256_output.write_text(
        "\n".join(hardware_manifest) + ("\n" if hardware_manifest else ""),
        encoding="utf-8",
    )
    print(text_report, end="")
    print(f"Environment text: {args.environment_output.resolve()}")
    print(f"Environment JSON: {args.environment_json.resolve()}")
    print(f"Hardware hashes: {args.hardware_sha256_output.resolve()}")
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
