# macOS POSIX-fallback benchmark baseline — 2026-05-18

This is a small human-readable summary of the benchmark matrix quick profile on the current macOS development environment. It is useful as a local fallback smoke baseline, not as Linux `io_uring` performance evidence.

## Reproduce

```sh
# Quick profile: one memory row and one persisted row.
bench/benchmark-matrix.sh --quick --output /tmp/phage-macos-fallback-baseline.jsonl
python3 -m json.tool /tmp/phage-macos-fallback-baseline-summary.json >/dev/null

# Fuller comparable local profile. Keep raw outputs in /tmp unless a ticket
# explicitly approves committing a small curated summary.
bench/benchmark-matrix.sh --profile full --output /tmp/phage-macos-fallback-matrix-full.jsonl
python3 -m json.tool /tmp/phage-macos-fallback-matrix-full-summary.json >/dev/null

# Linux io_uring evidence must be collected on Linux, not inferred from macOS.
bench/benchmark-matrix.sh --profile linux-io-uring --output /tmp/phage-linux-io-uring-matrix.jsonl
python3 -m json.tool /tmp/phage-linux-io-uring-matrix-summary.json >/dev/null
```

Generated JSONL, summary JSON, database, WAL, and log artifacts are local run artifacts. Leave them under `/tmp` and keep them out of git unless a future ticket explicitly asks for a curated committed summary.

## Run metadata

- Command: `bench/benchmark-matrix.sh --quick --output /tmp/phage-s3-macos-baseline-20260518-080104.jsonl`
- Raw output: `/tmp/phage-s3-macos-baseline-20260518-080104.jsonl` and `/tmp/phage-s3-macos-baseline-20260518-080104-summary.json` (not committed)
- Timestamp: `2026-05-18T07:01:04Z`
- Git revision: `0e47edab745fae81567e4dfac9679f07069ba9a5`
- Zig version: `0.15.2`
- OS/platform: `macOS-26.2-arm64-arm-64bit`
- Backend status: `macos-posix-fallback`
- Row count: 2 (`memory`: 1, `persisted`: 1)

## Representative quick-profile rows

| Mode | Ops | Value bytes | Batch | Read API | Write ops/sec | Read ops/sec | Total ops/sec | Write p95 | Read p99 |
|------|-----|-------------|-------|----------|---------------|--------------|---------------|-----------|----------|
| memory | 1,000 | 16 | 16 | getInto | 7,874,015.75 | 24,390,243.90 | 11,904,761.90 | 0.38 us | 1.00 us |
| persisted | 1,000 | 16 | 16 | getInto | 1,129,943.50 | 1,182,033.10 | 1,155,401.50 | 1.06 us | 1.00 us |

The persisted row used a disposable database path under `/tmp/phage-benchmark-matrix-4obdct2e/` and the matrix runner cleaned up generated store/WAL artifacts after the row.

## Interpretation

- macOS persisted rows exercise the POSIX fallback backend. They are good for checking that the matrix workflow, metadata, JSON parsing, and cleanup still work locally.
- These numbers should not be used to claim Linux `io_uring` throughput or latency.
- Compare future macOS fallback changes against this baseline only when the same quick profile and similar local load are used.
- Use the Linux profile on an appropriate Linux host for final storage-backend performance evidence.

## Related documents

- [Getting Started](../GETTING_STARTED.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [Benchmark Matrix and Linux io_uring Verification PRD](../prds/2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
