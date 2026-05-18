# WAL write-path baseline — 2026-05-18

Status: S1 baseline captured on macOS POSIX fallback before WAL clear/write-path optimization.
PRD slice: S1 — profile WAL write/clear cost and establish accepted baselines.

## Scope and instrumentation decision

No new benchmark source instrumentation was needed for this slice. The existing native benchmark and matrix runner already emit the stable fields needed for review: git revision, platform, Zig version, backend status, command, operation count, value size, batch size, read API, throughput, and p50/p95/p99 latency. The full matrix also covers persisted batch sizes `1`, `16`, and `64`, which is enough for S1 to compare `put` (`--batch-size 1`) against `putBatch` (`--batch-size >1`) and expose how WAL write/clear work amortizes across batches.

This baseline should not be used as Linux `io_uring` evidence. The backend status below is macOS POSIX fallback.

## Run metadata

- Baseline command: `bench/benchmark-matrix.sh --profile full --output /tmp/phage-wal-write-baseline-full.jsonl`
- Row output: `/tmp/phage-wal-write-baseline-full.jsonl` (not committed)
- Summary output: `/tmp/phage-wal-write-baseline-full-summary.json` (not committed)
- Quick smoke command: `bench/benchmark-matrix.sh --quick --ops 1000 --output /tmp/phage-wal-write-baseline-quick.jsonl`
- Quick smoke summary: `/tmp/phage-wal-write-baseline-quick-summary.json` validated with `python3 -m json.tool` (not committed)
- Git revision: `1d00e5d6ef737ff5a79374d82f790aac181c04f1`
- Zig version: `0.15.2`
- OS/platform: `macOS-26.2-arm64-arm-64bit`
- Backend status: `macos-posix-fallback`
- Matrix profile: `full`
- Timestamp: `2026-05-18T14:30:16Z`
- Row count: 24 (`memory`: 12, `persisted`: 12)

## Persisted write-path rows: value size 16, read API get-into

| Batch | Operation count | Write ops/sec | Read ops/sec | Total ops/sec | Write p50/p95/p99 (us) | Read p50/p95/p99 (us) | Matrix row |
| ---: | ---: | ---: | ---: | ---: | --- | --- | ---: |
| 1 | 10,000 | 29,428.47 | 130,471.66 | 48,024.51 | 25.00 / 32.00 / 41.00 | 1.00 / 1.00 / 1.00 | 13 |
| 16 | 10,000 | 144,446.05 | 134,129.17 | 139,094.63 | 1.94 / 2.63 / 82.94 | 1.00 / 1.00 / 1.00 | 15 |
| 64 | 10,000 | 236,680.79 | 135,960.08 | 172,705.61 | 0.66 / 0.94 / 36.39 | 1.00 / 1.00 / 1.00 | 17 |

## Commands for the baseline rows

- Batch 1: `zig build -Doptimize=ReleaseFast benchmark -- 10000 --mode persisted --value-size 16 --batch-size 1 --read-api get-into --json --db-path /tmp/phage-benchmark-matrix-erq3jcez/phage-matrix-row-13-v16-b1-get-into`
- Batch 16: `zig build -Doptimize=ReleaseFast benchmark -- 10000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --json --db-path /tmp/phage-benchmark-matrix-erq3jcez/phage-matrix-row-15-v16-b16-get-into`
- Batch 64: `zig build -Doptimize=ReleaseFast benchmark -- 10000 --mode persisted --value-size 16 --batch-size 64 --read-api get-into --json --db-path /tmp/phage-benchmark-matrix-erq3jcez/phage-matrix-row-17-v16-b64-get-into`

All persisted `db_path` values were generated under `/tmp/phage-benchmark-matrix-*`; the matrix runner removed each database and `.wal` file after the corresponding row and removed the temporary root at the end of the run.

## `put` vs `putBatch` implications

- `--batch-size 1` uses `Phage.put` for each write. Each operation writes the data entry and WAL entry, waits for I/O, updates the index, and then calls `Wal.clear`. On this run, that path reached only 29,428.47 write ops/sec with write p95 32.00 us.
- `--batch-size 16` and `--batch-size 64` use `Phage.putBatch`. The implementation coalesces data entries and WAL entries into one main-file write and one WAL write per batch, waits once, updates the index in batch, and calls `Wal.clear` once per batch. This amortizes WAL clear/truncate/fsync overhead across many logical writes.
- The batch-size trend is therefore the current reviewable proxy for WAL write/clear cost: moving from batch 1 to batch 64 improved write throughput from 29,428.47 to 236,680.79 ops/sec and reduced write p95 from 32.00 us to 0.94 us on macOS POSIX fallback. Future S2 changes should compare against this table without relabeling the numbers as Linux `io_uring` results.

## Verification

- `zig build test` passed on macOS with Zig 0.15.2.
- `bench/benchmark-matrix.sh --quick --ops 1000 --output /tmp/phage-wal-write-baseline-quick.jsonl` passed; summary JSON validated; `row_count=2`; `backend_status=macos-posix-fallback`; persisted artifacts cleaned.
- `bench/benchmark-matrix.sh --profile full --output /tmp/phage-wal-write-baseline-full.jsonl` passed; summary JSON validated; `row_count=24`; `backend_status=macos-posix-fallback`; persisted artifacts cleaned.
- No raw JSONL, summary JSON, database, WAL, `.compact.tmp`, or log artifacts are intended for git.

## Related documents

- [WAL write-path optimization PRD](../prds/2026-05-18-phage-wal-write-path-optimization-prd.md)
- [WAL write-path optimization evidence](2026-05-18-wal-write-path-optimization.md)
- [macOS POSIX-fallback benchmark baseline](2026-05-18-macos-fallback-baseline.md)
- [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
