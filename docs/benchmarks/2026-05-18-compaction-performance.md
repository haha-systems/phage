# Compaction benchmark and status evidence — 2026-05-18

Status: S3 curated evidence for the compaction performance and safety PRD.
PRD slice: S3 — document compaction benchmark evidence and user-facing status.

This note records curated benchmark and review evidence only. Raw JSONL, summary JSON, database, WAL, `.compact.tmp`, and log artifacts are local run outputs and are intentionally not committed.

## Scope

The accepted compaction work in this loop is:

- `7cffd33ad97a48b3679461636617db1fc45d1c56` — `feat(benchmark): add compaction workload profile`
- `f86c4a8b87458eaae15551ddc898039309051d63` — `fix(io): harden failed compaction cleanup`

The S1 benchmark change adds a native `--profile compaction` persisted workload and a `bench/benchmark-matrix.sh --profile compaction` row. It is measurement-only: no storage behavior files changed in S1.

The S2 storage change is a bounded safety/clarity improvement, not a throughput optimization claim. Failed inline compaction now resets its in-progress flag, removes stale/failed `.compact.tmp` paths, delays index-offset publication until copy plus swap succeeds, opens the temporary file with exclusive creation after stale cleanup, and keeps the old data file descriptor open until replacement reopen succeeds. Comments/logs now describe compaction as inline when the threshold is reached, not as background or non-blocking.

Scope note: this S3 documentation card depends on the S2 review and curates S1/S2 evidence. Follow-up hardening cards created from `t_921cc8dc`, including later mutation-serialization work, are separate from this S3 evidence slice and should not be treated as accepted documentation evidence here until their own review lane completes.

## Supported local compaction commands

Direct one-shot smoke, as used by the accepted S1/S2 evidence:

```sh
zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-compaction-smoke > /tmp/phage-compaction-smoke.json
python3 -m json.tool /tmp/phage-compaction-smoke.json >/dev/null
```

Matrix profile smoke, as used by the accepted S1 review evidence:

```sh
bench/benchmark-matrix.sh --profile compaction --output /tmp/phage-compaction-profile.jsonl
python3 -m json.tool /tmp/phage-compaction-profile-summary.json >/dev/null
```

The compaction profile interprets positional `OPS` as live-key count, performs the initial live-key load plus `--update-rounds` update passes, and reports `operation_count = live_key_count * (update_rounds + 1)`. Persisted runs should use explicit `/tmp/...` database paths and should leave database, `.wal`, and `.compact.tmp` files unstaged and preferably removed.

## macOS POSIX-fallback evidence

All rows in this section were collected on macOS and exercise the POSIX fallback backend. They are useful for local compaction smoke/status evidence and must not be relabeled as Linux `io_uring` evidence.

Host/tool metadata for the accepted local evidence:

- S1 measurement git revision: `7cffd33ad97a48b3679461636617db1fc45d1c56`
- S2 safety-hardening git revision: `f86c4a8b87458eaae15551ddc898039309051d63`
- Zig version: `0.15.2`
- OS/platform: `macOS-26.2-arm64-arm-64bit`
- Backend status: `macos-posix-fallback`

### Representative compaction rows

| Source | Git revision | Command shape | Live keys | Operation count | Value bytes | Update rounds | Triggered / count | Waste before → after | File size before → after | Reduction bytes | Write ops/sec | Write p50/p95/p99 (us) | Trigger latency (us) |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- | ---: | ---: | --- | ---: |
| S1 implementation direct smoke | `7cffd33` | `zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-compaction-s1-smoke` | 64 | 192 | 64 | 2 | true / 2 | 0.496055 → 0.0 | 9,759 → 4,918 | 9,682 | 57,605.76 | 13 / 18 / 283 | 333 |
| S1 reviewer matrix row | `7cffd33` | `bench/benchmark-matrix.sh --profile compaction --output /tmp/phage-compaction-s1-review-15810-profile.jsonl` | 128 | 384 | 64 | 2 | true / 2 | 0.498017 → 0.0 | not recorded in review table | not recorded in review table | 61,825.79 | 13 / 16 / 25 | 591 |
| S2 implementation direct smoke | `f86c4a8` | `zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-compaction-s2-smoke-final2-19378` | 64 | 192 | 64 | 2 | true / 2 | 0.496055 → 0.0 | 9,759 → 4,918 | 9,682 | 6,865.73 | 99 / 155 / 1,713 | 4,901 |
| S2 reviewer direct smoke | `f86c4a8` | `zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-compaction-s2-review3-20495` | 64 | 192 | 64 | 2 | true / 2 | 0.496055 → 0.0 | 9,759 → 4,918 | 9,682 | 44,933.30 | 14 / 31 / 315 | 377 |

Interpretation:

- The accepted compaction profile reliably creates update-heavy waste and observes compaction on the macOS POSIX fallback path.
- The comparable 64-live-key rows consistently report `triggered=true`, `trigger_count=2`, `waste_ratio_before=0.496055`, `waste_ratio_after=0.0`, `file_size_before=9759`, `file_size_after=4918`, and `file_size_reduction_bytes=9682`.
- S2 should be read as safety hardening and truthful inline-compaction semantics. The local latency and throughput rows are noisy and should not be used to claim a compaction performance win or regression.
- The benchmark evidence shows caller-visible inline trigger latency for the current implementation; it does not support a background/non-blocking compaction claim.

## Linux `io_uring` status

No compaction-specific Linux `io_uring` benchmark row has been accepted in this S3 slice. That verification is intentionally separated into the downstream S4 Linux compaction card so macOS POSIX-fallback evidence is not conflated with Linux backend evidence.

Current related Linux status:

- The WAL write-path Linux verification is already documented in [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md), but those are WAL/matrix rows, not compaction-profile evidence.
- A future compaction Linux run should record `uname -a`, `zig version`, full git revision, `metadata.backend_status=linux-io-uring-intended`, `zig build test`, `bench/benchmark-matrix.sh --profile compaction ...`, summary JSON validation, representative compaction fields, and cleanup status.

## Correctness and review evidence

S1 review approved commit `7cffd33` with these key findings:

- The diff was limited to benchmark/matrix/test instrumentation: `src/benchmark.zig`, `bench/benchmark_matrix.py`, and `bench/test_benchmark_matrix.py`.
- Required compaction fields were present in matrix and direct native smoke output.
- Existing quick benchmark profile and `zig build test` passed.
- No generated JSONL, summary JSON, database, WAL, `.compact.tmp`, or log artifacts were staged.

S2 review approved commit `f86c4a8` with these key findings:

- The diff was limited to `src/root.zig` and `src/test_wal_compaction_correctness.zig`.
- The new regression covers failed inline compaction cleanup, flag reset, temporary-file removal, and live index-entry readability after copy failure.
- `zig build test` passed, including existing compaction and WAL/recovery coverage.
- The S2 reviewer reran a macOS POSIX-fallback compaction smoke and confirmed `triggered=true`, `trigger_count=2`, and no generated artifacts staged.

Broader compaction/write concurrency and pathological post-rename reopen policy remain outside this S3 documentation slice and were routed to follow-up card `t_921cc8dc` by the S2 worker/reviewer lane.

## Artifact hygiene

Raw artifacts from this PRD loop remain local only and are not committed. Examples from the accepted S1/S2 evidence include:

- `/tmp/phage-compaction-s1-quick.jsonl` and `/tmp/phage-compaction-s1-quick-summary.json`
- `/tmp/phage-compaction-s1-profile.jsonl` and `/tmp/phage-compaction-s1-profile-summary.json`
- `/tmp/phage-compaction-s1-smoke.json`
- `/tmp/phage-compaction-s2-smoke-final2-19378.json`

The accepted S1/S2 handoffs and reviews confirmed the direct-smoke database, `.wal`, and `.compact.tmp` paths were absent after the runs. S3 docs verification also ran a local compaction smoke and matrix row under `/tmp` to spot-check the current command shape, but those raw outputs remain uncommitted and are not used as new source-commit evidence in the table above.

Repository-root `matrix.json-summary.json` was already present as an untracked generated-looking file before this S3 docs work and remains unstaged.

## Related documents

- [Compaction performance and safety PRD](../prds/2026-05-18-phage-compaction-performance-prd.md)
- [WAL write-path optimization evidence](2026-05-18-wal-write-path-optimization.md)
- [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [Getting Started](../GETTING_STARTED.md)
