# WAL write-path optimization evidence — 2026-05-18

Status: S3 curated evidence for the WAL write-path optimization PRD.
PRD slice: S3 — document before/after persisted write evidence.

This note records only curated benchmark evidence. Raw JSONL, summary JSON, database, and WAL artifacts are local run outputs and are intentionally not committed.

## Scope

The optimization under review is the S2 change in `src/io/wal.zig`:

- `ddc8c91` — `test(io): cover WAL clear recovery invariants`
- `2be5330` — `perf(io): reduce WAL clear overhead`

`Wal.clear` now skips work when the tracked WAL size is already zero and no longer rewinds the file descriptor cursor for non-empty clears. Non-empty WAL clears still use `ftruncate` followed by `fsync`, so the benchmark evidence below should be read as a reduced-overhead WAL clear result, not as a relaxed durability contract.

## macOS POSIX-fallback evidence

These rows were collected on macOS and exercise the POSIX fallback backend. They are useful for local before/after comparison and should not be relabeled as Linux `io_uring` evidence.

### Before-change baseline

- Evidence source: [WAL write-path baseline](2026-05-18-wal-write-path-baseline.md)
- Baseline command: `bench/benchmark-matrix.sh --profile full --output /tmp/phage-wal-write-baseline-full.jsonl`
- Row output: `/tmp/phage-wal-write-baseline-full.jsonl` (not committed)
- Summary output: `/tmp/phage-wal-write-baseline-full-summary.json` (not committed)
- Measured git revision: `1d00e5d6ef737ff5a79374d82f790aac181c04f1`
- Baseline doc commit: `17ce841 docs(benchmark): record WAL write-path baseline`
- Zig version: `0.15.2`
- OS/platform: `macOS-26.2-arm64-arm-64bit`
- Backend status: `macos-posix-fallback`
- Matrix profile: `full`
- Timestamp: `2026-05-18T14:30:16Z`
- Row count: 24 (`memory`: 12, `persisted`: 12)

### After-change quick smoke

- Evidence source: S2 implementation handoff and S2 reviewer rerun.
- Implementation quick command: `bench/benchmark-matrix.sh --quick --ops 1000 --output /tmp/phage-wal-write-optimized-quick.jsonl`
- Implementation quick summary validation: `python3 -m json.tool /tmp/phage-wal-write-optimized-quick-summary.json >/dev/null`
- Reviewer quick command: `bench/benchmark-matrix.sh --quick --ops 1000 --output /tmp/phage-wal-s2-review-quick.jsonl`
- Reviewer quick summary validation: `python3 -m json.tool /tmp/phage-wal-s2-review-quick-summary.json >/dev/null`
- Measured git revision: `2be533010aed8cff7ebbf06c7551e36bfa1710d1`
- Zig version: `0.15.2`
- OS/platform: `macOS-26.2-arm64-arm-64bit`
- Backend status: `macos-posix-fallback`
- Matrix profile: `quick`
- Row count: 2 (`memory`: 1, `persisted`: 1)
- Implementation timestamp: `2026-05-18T14:42:06Z`
- Reviewer timestamp: `2026-05-18T14:47:21Z`

Representative persisted quick rows:

| Source | Ops | Value bytes | Batch | Read API | Write ops/sec | Total ops/sec | Write p50/p95/p99 (us) |
| --- | ---: | ---: | ---: | --- | ---: | ---: | --- |
| S2 implementation quick | 1,000 | 16 | 16 | `getInto` | 831,255.20 | 973,236.01 | 1.06 / 1.56 / 3.19 |
| S2 reviewer quick rerun | 1,000 | 16 | 16 | `getInto` | 769,822.94 | 932,400.93 | 1.00 / 1.88 / 5.56 |

Persisted quick-row commands emitted by the matrix runner:

- Implementation quick persisted row: `zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --json --db-path /tmp/phage-benchmark-matrix-o3jreocp/phage-matrix-row-01-v16-b16-get-into`
- Reviewer quick persisted row: `zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --json --db-path /tmp/phage-benchmark-matrix-84y_492i/phage-matrix-row-01-v16-b16-get-into`

The S2 reviewer confirmed both quick persisted database paths and their `.wal` files were cleaned after the run.

### Before/after targeted persisted rows

S2 also ran one-shot persisted benchmarks at the same value size, read API, operation count, and batch sizes as the S1 full-profile baseline. These are the primary macOS fallback before/after rows.

After-change one-shot commands:

```sh
zig build -Doptimize=ReleaseFast benchmark -- 10000 --mode persisted --value-size 16 --batch-size 1 --read-api get-into --json --db-path /tmp/phage-wal-opt-b1-2be5330 > /tmp/phage-wal-opt-b1-2be5330.json
zig build -Doptimize=ReleaseFast benchmark -- 10000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --json --db-path /tmp/phage-wal-opt-b16-2be5330 > /tmp/phage-wal-opt-b16-2be5330.json
zig build -Doptimize=ReleaseFast benchmark -- 10000 --mode persisted --value-size 16 --batch-size 64 --read-api get-into --json --db-path /tmp/phage-wal-opt-b64-2be5330 > /tmp/phage-wal-opt-b64-2be5330.json
```

After-change output row count: 3 persisted one-shot JSON rows. The `/tmp/phage-wal-opt-b{1,16,64}-2be5330` database paths and matching `.wal` files were absent after cleanup; the JSON row outputs were left under `/tmp` and are not committed.

| Batch | Ops | Value bytes | Read API | Before write ops/sec | After write ops/sec | Delta | Before write p50/p95/p99 (us) | After write p50/p95/p99 (us) |
| ---: | ---: | ---: | --- | ---: | ---: | ---: | --- | --- |
| 1 | 10,000 | 16 | `getInto` | 29,428.47 | 33,899.22 | +15.19% | 25.00 / 32.00 / 41.00 | 25.00 / 32.00 / 39.00 |
| 16 | 10,000 | 16 | `getInto` | 144,446.05 | 165,316.58 | +14.45% | 1.94 / 2.63 / 82.94 | 2.00 / 2.69 / 3.63 |
| 64 | 10,000 | 16 | `getInto` | 236,680.79 | 270,518.86 | +14.30% | 0.66 / 0.94 / 36.39 | 0.67 / 0.89 / 1.03 |

Interpretation:

- The measured macOS fallback write-throughput gain is roughly 14–15% across batch sizes 1, 16, and 64.
- Batch-size 1 remains much slower than batched writes because `put` still commits and clears the WAL per logical write.
- The large before-change p99 spikes for batch 16 and 64 did not recur in the S2 one-shot rows, but they should be treated as local benchmark observations rather than a hard tail-latency guarantee.

## Linux `io_uring` status

Post-optimization Linux `io_uring` evidence is now verified by S4 rather than inferred from macOS rows.

Current dependency status:

- Existing Linux remediation `t_c54e96cd` is complete. Commit `bc23f18` fixes zero-length `io_uring` reads by returning an already-completed no-op for empty buffers, and the Linux rerun confirmed the prior WAL empty-value recovery failure now passes.
- S4 follow-up `t_701f3017` reran on OrbStack NixOS 25.11 arm64 at `c979895847d7136bce83811e53314c3356fb5048`, which includes `bc23f18`, `ddc8c91`, `2be5330`, and this docs evidence commit's parent.
- Historical Linux matrix evidence remains recorded in [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md); that document now also records the post-remediation WAL write-path verification table.

S4 Linux commands:

```sh
git status --short --untracked-files=all
uname -a
zig version
zig build test
bench/benchmark-matrix.sh --quick --output /tmp/phage-linux-wal-write-quick.jsonl
python3 -m json.tool /tmp/phage-linux-wal-write-quick-summary.json >/dev/null
bench/benchmark-matrix.sh --profile linux-io-uring --ops 1000 --output /tmp/phage-linux-wal-write-matrix-ops1000.jsonl
python3 -m json.tool /tmp/phage-linux-wal-write-matrix-ops1000-summary.json >/dev/null
```

S4 Linux summary:

- Host: `Linux phage-nixos 7.0.5-orbstack-00330-ge3df4e19b0a0-dirty ... aarch64 GNU/Linux`
- Zig version: `0.15.2`
- `zig build test`: passed on Linux `io_uring`; the previous `write_ahead_log:recover_committed_empty_put_at_zero_offset` failure passed.
- Quick matrix: `metadata.backend_status=linux-io-uring-intended`, `row_count=2`, `rows_by_mode.memory=1`, `rows_by_mode.persisted=1`, summary JSON validated.
- `linux-io-uring --ops 1000` profile: `metadata.backend_status=linux-io-uring-intended`, `row_count=24`, `rows_by_mode.memory=12`, `rows_by_mode.persisted=12`, summary JSON validated.

Representative post-optimization Linux persisted rows:

| Source | Ops | Value bytes | Batch | Read API | Write ops/sec | Total ops/sec | Write p50/p95/p99 (us) |
| --- | ---: | ---: | ---: | --- | ---: | ---: | --- |
| S4 quick row 1 | 1,000 | 16 | 16 | `getInto` | 2,132,196.16 | 728,874.13 | 0.32 / 0.63 / 1.94 |
| S4 profile row 12 | 1,000 | 16 | 1 | `get` | 107,366.22 | 108,844.53 | 4.88 / 22.50 / 27.63 |
| S4 profile row 15 | 1,000 | 16 | 16 | `getInto` | 751,667.76 | 439,842.42 | 1.18 / 1.84 / 1.91 |
| S4 profile row 23 | 1,000 | 256 | 64 | `getInto` | 870,164.50 | 122,802.35 | 0.65 / 6.70 / 6.70 |

The S4 run confirms Linux correctness and `metadata.backend_status=linux-io-uring-intended` for the optimized WAL write path. The cheap 1,000-op Linux rows are useful status evidence but should not be read as a definitive throughput win/loss claim versus the earlier Ubuntu run.

## Verification and artifact hygiene

- S2 implementation verified `zig fmt src build.zig` and `zig build test` on macOS.
- S2 review reran `zig build test`, quick matrix smoke, JSON validation, and diff checks.
- Raw artifacts remain local only: `/tmp/phage-wal-write-optimized-quick.jsonl`, `/tmp/phage-wal-write-optimized-quick-summary.json`, `/tmp/phage-wal-s2-review-quick.jsonl`, `/tmp/phage-wal-s2-review-quick-summary.json`, `/tmp/phage-wal-opt-b{1,16,64}-2be5330.json`, `/tmp/phage-linux-wal-write-quick.jsonl`, `/tmp/phage-linux-wal-write-quick-summary.json`, `/tmp/phage-linux-wal-write-matrix-ops1000.jsonl`, and `/tmp/phage-linux-wal-write-matrix-ops1000-summary.json` are not committed.
- Repository-root `matrix.json-summary.json` was already present as an untracked generated-looking file before this S3 docs commit and remains unstaged.

## Related documents

- [WAL write-path optimization PRD](../prds/2026-05-18-phage-wal-write-path-optimization-prd.md)
- [WAL write-path baseline](2026-05-18-wal-write-path-baseline.md)
- [macOS POSIX-fallback benchmark baseline](2026-05-18-macos-fallback-baseline.md)
- [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
