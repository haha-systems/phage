#!/usr/bin/env python3
"""Run Phage native benchmark profiles and emit JSONL plus a summary JSON."""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional


TMP_ROOT_DIR = "/tmp"
TMP_ROOT_PREFIX = "phage-benchmark-matrix-"


def make_tmp_root() -> str:
    return tempfile.mkdtemp(prefix=TMP_ROOT_PREFIX, dir=TMP_ROOT_DIR)


@dataclass(frozen=True)
class MatrixRow:
    index: int
    mode: str
    ops: int
    value_size: int
    batch_size: int
    read_api: str
    db_path: Optional[str] = None


def profile_rows(profile: str, ops: Optional[int] = None, tmp_root: Optional[str] = None) -> List[MatrixRow]:
    if profile == "quick":
        profile_ops = 1000 if ops is None else ops
        dimensions = [
            ("memory", 16, 16, "get-into"),
            ("persisted", 16, 16, "get-into"),
        ]
    elif profile in ("full", "linux-io-uring"):
        profile_ops = 10000 if ops is None else ops
        dimensions = [
            (mode, value_size, batch_size, read_api)
            for mode in ("memory", "persisted")
            for value_size in (16, 256)
            for batch_size in (1, 16, 64)
            for read_api in ("get", "get-into")
        ]
    else:
        raise ValueError(f"unknown benchmark matrix profile: {profile}")

    root = tmp_root or make_tmp_root()
    rows: List[MatrixRow] = []
    for index, (mode, value_size, batch_size, read_api) in enumerate(dimensions):
        db_path = None
        if mode == "persisted":
            db_path = os.path.join(
                root,
                f"phage-matrix-row-{index:02d}-v{value_size}-b{batch_size}-{read_api}",
            )
        rows.append(
            MatrixRow(
                index=index,
                mode=mode,
                ops=profile_ops,
                value_size=value_size,
                batch_size=batch_size,
                read_api=read_api,
                db_path=db_path,
            )
        )
    return rows


def cleanup_targets(row: MatrixRow) -> List[str]:
    if row.db_path is None:
        return []
    return [row.db_path, row.db_path + ".wal"]


def cleanup_row(row: MatrixRow) -> None:
    for target in cleanup_targets(row):
        try:
            os.remove(target)
        except FileNotFoundError:
            pass


def benchmark_command(row: MatrixRow) -> List[str]:
    command = [
        "zig",
        "build",
        "-Doptimize=ReleaseFast",
        "benchmark",
        "--",
        str(row.ops),
        "--mode",
        row.mode,
        "--value-size",
        str(row.value_size),
        "--batch-size",
        str(row.batch_size),
        "--read-api",
        row.read_api,
        "--json",
    ]
    if row.db_path is not None:
        command.extend(["--db-path", row.db_path])
    return command


def _read_api_matches(expected: str, actual: str) -> bool:
    return expected == actual or (expected == "get-into" and actual == "getInto")


def enrich_row(row: MatrixRow, benchmark_stdout: str, metadata: Dict[str, Any]) -> Dict[str, Any]:
    parsed = json.loads(benchmark_stdout)
    mismatches = []
    if parsed.get("mode") != row.mode:
        mismatches.append("mode")
    if parsed.get("operation_count") != row.ops:
        mismatches.append("operation_count")
    if parsed.get("value_size") != row.value_size:
        mismatches.append("value_size")
    if parsed.get("batch_size") != row.batch_size:
        mismatches.append("batch_size")
    if not _read_api_matches(row.read_api, parsed.get("read_api")):
        mismatches.append("read_api")
    if mismatches:
        raise ValueError(f"benchmark row {row.index} output did not match command fields: {', '.join(mismatches)}")

    enriched: Dict[str, Any] = {
        "type": "benchmark_row",
        "row_index": row.index,
        "profile": metadata["profile"],
        "backend_status": metadata["backend_status"],
        "git_revision": metadata["git_revision"],
        "os_platform": metadata["os_platform"],
        "zig_version": metadata["zig_version"],
        "timestamp": metadata["timestamp"],
        "command": " ".join(benchmark_command(row)),
        "db_path": row.db_path,
    }
    enriched.update(parsed)
    return enriched


def build_summary(metadata: Dict[str, Any], rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    best = None
    if rows:
        best = max(rows, key=lambda row: row["throughput"]["total_ops_per_sec"])
    by_mode: Dict[str, int] = {}
    for row in rows:
        by_mode[row["mode"]] = by_mode.get(row["mode"], 0) + 1
    return {
        "type": "benchmark_summary",
        "metadata": metadata,
        "row_count": len(rows),
        "rows_by_mode": by_mode,
        "best_total_ops_per_sec": best,
        "schema_notes": [
            "Stable automation fields: type, row_count, metadata.profile, metadata.git_revision, metadata.os_platform, metadata.zig_version, metadata.backend_status, metadata.timestamp, mode, operation_count, value_size, batch_size, read_api, throughput, latency_us.",
            "Informational metadata fields such as command and platform strings may vary across machines and shells.",
        ],
    }


def detect_backend_status() -> str:
    system = platform.system()
    if system == "Darwin":
        return "macos-posix-fallback"
    if system == "Linux":
        return "linux-io-uring-intended"
    return "posix-fallback"


def command_output(args: List[str], default: str) -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip() or default
    except (OSError, subprocess.CalledProcessError):
        return default


def build_metadata(profile: str, command: Iterable[str]) -> Dict[str, Any]:
    return {
        "profile": profile,
        "git_revision": command_output(["git", "rev-parse", "HEAD"], "unknown"),
        "os_platform": platform.platform(),
        "zig_version": command_output(["zig", "version"], "unknown"),
        "backend_status": detect_backend_status(),
        "timestamp": _datetime.datetime.now(_datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "command": " ".join(command),
        "generated_by": "bench/benchmark-matrix.sh",
    }


def summary_path_for(output_path: pathlib.Path) -> pathlib.Path:
    if output_path.name.endswith(".jsonl"):
        return output_path.with_name(output_path.name[: -len(".jsonl")] + "-summary.json")
    return output_path.with_name(output_path.name + "-summary.json")


def run_matrix(profile: str, output_path: pathlib.Path, summary_path: pathlib.Path, ops: Optional[int]) -> Dict[str, Any]:
    tmp_root = make_tmp_root()
    metadata = build_metadata(profile, sys.argv)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    rows = profile_rows(profile, ops=ops, tmp_root=tmp_root)
    enriched_rows: List[Dict[str, Any]] = []
    try:
        with output_path.open("w", encoding="utf-8") as output_file:
            for row in rows:
                cleanup_row(row)
                try:
                    completed = subprocess.run(
                        benchmark_command(row),
                        check=True,
                        text=True,
                        stdout=subprocess.PIPE,
                    )
                    enriched = enrich_row(row, completed.stdout, metadata)
                    enriched_rows.append(enriched)
                    output_file.write(json.dumps(enriched, sort_keys=True) + "\n")
                    output_file.flush()
                finally:
                    cleanup_row(row)
        summary = build_summary(metadata, enriched_rows)
        summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return summary
    finally:
        for row in rows:
            cleanup_row(row)
        shutil.rmtree(tmp_root, ignore_errors=True)


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Phage benchmark matrix profiles and emit JSONL plus summary JSON.")
    profile = parser.add_mutually_exclusive_group()
    profile.add_argument("--quick", action="store_true", help="Run the cheap reviewer/audit profile.")
    profile.add_argument("--profile", choices=("quick", "full", "linux-io-uring"), help="Benchmark profile to run.")
    parser.add_argument("--ops", type=int, help="Override operation count for every matrix row.")
    parser.add_argument("--output", required=True, help="JSON Lines output path for row-level benchmark data.")
    parser.add_argument("--summary-output", help="Compact summary JSON path; defaults to OUTPUT with -summary.json suffix.")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    profile = args.profile or "quick"
    if args.quick:
        profile = "quick"
    output_path = pathlib.Path(args.output)
    summary_path = pathlib.Path(args.summary_output) if args.summary_output else summary_path_for(output_path)
    summary = run_matrix(profile, output_path, summary_path, args.ops)
    print(f"benchmark matrix profile={profile} rows={summary['row_count']} output={output_path} summary={summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
