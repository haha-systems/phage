# Linux io_uring benchmark verification

Date: 2026-05-18
Status: Linux `io_uring` correctness, WAL write-path evidence, and compaction-profile follow-up verified on OrbStack Linux
PRD slice: S4 Linux io_uring verification path

## Status summary

The original S4 worker ran on macOS and correctly refused to treat POSIX-fallback numbers as Linux `io_uring` evidence. A follow-up approved Linux execution path became available through OrbStack, and the Linux benchmark matrix workflow completed both the quick smoke and a fuller `linux-io-uring` profile on an Ubuntu 24.04 arm64 machine. A later compaction-specific S4 follow-up also verified the compaction profile and current compaction safety/read-serialization behavior on OrbStack `phage-linux` with `metadata.backend_status=linux-io-uring-intended`.

Linux status for this slice: `verified after remediation`.

The first Linux correctness run exposed an `io_uring` backend failure in WAL empty-value recovery. Remediation card `t_c54e96cd` fixed that path in `bc23f18` by treating zero-length `io_uring` reads as completed no-ops. The WAL write-path optimization PRD S4 rerun then verified current HEAD `c979895847d7136bce83811e53314c3356fb5048` on OrbStack NixOS: Linux `zig build test` passed, the quick matrix summary validated with `metadata.backend_status=linux-io-uring-intended`, and the cheap `linux-io-uring` profile validated with 24 rows.

## Worker and backend capability checks

### macOS worker check

This repository-local worker environment is macOS, so local persisted benchmark numbers exercise the POSIX fallback backend and must not be relabeled as Linux evidence.

```text
$ uname -a
Darwin ari.local 25.2.0 Darwin Kernel Version 25.2.0: Tue Nov 18 21:08:48 PST 2025; root:xnu-12377.61.12~1/RELEASE_ARM64_T8132 arm64

$ zig version
0.15.2

$ bench/benchmark-matrix.sh --quick --ops 10 --output /tmp/phage-s4-capability-matrix.jsonl
benchmark matrix profile=quick rows=2 output=/tmp/phage-s4-capability-matrix.jsonl summary=/tmp/phage-s4-capability-matrix-summary.json

/tmp/phage-s4-capability-matrix-summary.json metadata:
profile=quick
backend_status=macos-posix-fallback
os_platform=macOS-26.2-arm64-arm-64bit
zig_version=0.15.2
git_revision=0e47edab745f
row_count=2
```

Zig backend source selects `io_uring` only when the target OS is Linux:

```zig
pub const default_kind: BackendKind = if (builtin.os.tag == .linux) .linux_iouring else .posix;
```

### OrbStack Linux check

OrbStack provided an approved Linux execution path after the initial macOS blocker. The Linux benchmark handoff recorded:

```text
$ orbctl version
Version: 2.1.3 (2010300)

Machine: phage-linux
Distro: ubuntu noble/24.04
Architecture: arm64

$ uname -a
Linux phage-linux 7.0.5-orbstack-00330-ge3df4e19b0a0-dirty #1 SMP PREEMPT Sun May 10 11:47:42 UTC 2026 aarch64 GNU/Linux

$ zig version
0.15.2

Repository clone: /home/xiy/phage-linux
Git revision: 7537c2ae928d845f756a250ea40c67d84058085b
```

## Linux commands run

The Linux run used a native Linux filesystem clone rather than the macOS working tree:

```sh
git clone /mnt/mac/Users/xiy/code/phage /home/xiy/phage-linux
cd /home/xiy/phage-linux

zig build test

bench/benchmark-matrix.sh --quick --ops 10 --output /tmp/phage-linux-io-uring-quick.jsonl
python3 -m json.tool /tmp/phage-linux-io-uring-quick-summary.json >/dev/null

bench/benchmark-matrix.sh --profile linux-io-uring --ops 1000 --output /tmp/phage-linux-io-uring-matrix-ops1000.jsonl
python3 -m json.tool /tmp/phage-linux-io-uring-matrix-ops1000-summary.json >/dev/null
```

`--ops 1000` was used for the fuller profile to keep the Linux verification cheap while preserving the `linux-io-uring` profile dimensions. Raw JSONL and summary artifacts stayed under `/tmp` and were not committed.

## Benchmark evidence

### Quick Linux matrix smoke

Result: passed.

Summary:

- `metadata.backend_status=linux-io-uring-intended`
- `row_count=2`
- `rows_by_mode.memory=1`
- `rows_by_mode.persisted=1`

### Fuller Linux io_uring profile

Result: passed with `--ops 1000`.

Summary:

- `metadata.profile=linux-io-uring`
- `metadata.backend_status=linux-io-uring-intended`
- `row_count=24`
- `rows_by_mode.memory=12`
- `rows_by_mode.persisted=12`

Representative rows from the fuller profile:

| Row | Mode | Value size | Batch size | Read API | Total ops/sec | Write ops/sec | Read ops/sec | Write p50/p95/p99 (us) | Read p50/p95/p99 (us) |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | --- | --- |
| Best total | memory | 16 | 64 | `getInto` | 11,898,812.50 | 8,247,422.68 | 21,371,174.56 | 0.02 / 0.20 / 0.20 | 0.00 / 0.04 / 0.04 |
| 12 | persisted | 16 | 1 | `get` | 250,529.78 | 178,690.16 | 418,970.31 | 4.67 / 7.71 / 21.17 | 2.25 / 2.38 / 3.08 |
| 23 | persisted | 256 | 64 | `getInto` | 629,595.85 | 1,495,226.49 | 398,993.90 | 0.52 / 0.73 / 0.78 | 2.04 / 2.21 / 35.17 |

Persisted `db_path` and `.wal` artifacts for representative rows were cleaned up under `/tmp/phage-benchmark-matrix-*`.

### Post-remediation WAL write-path S4 rerun

Result: passed on OrbStack NixOS 25.11 arm64 after `bc23f18` and after the WAL clear optimization commits `ddc8c91`/`2be5330`.

Host and tool evidence:

```text
$ uname -a
Linux phage-nixos 7.0.5-orbstack-00330-ge3df4e19b0a0-dirty #1 SMP PREEMPT Sun May 10 11:47:42 UTC 2026 aarch64 GNU/Linux

$ zig version
0.15.2

$ git rev-parse HEAD
c979895847d7136bce83811e53314c3356fb5048
```

Verification commands:

```sh
zig build test
bench/benchmark-matrix.sh --quick --output /tmp/phage-linux-wal-write-quick.jsonl
python3 -m json.tool /tmp/phage-linux-wal-write-quick-summary.json >/dev/null
bench/benchmark-matrix.sh --profile linux-io-uring --ops 1000 --output /tmp/phage-linux-wal-write-matrix-ops1000.jsonl
python3 -m json.tool /tmp/phage-linux-wal-write-matrix-ops1000-summary.json >/dev/null
```

Linux `zig build test` passed on the `io_uring` path. The previously failing `write_ahead_log:recover_committed_empty_put_at_zero_offset` regression passed, as did the backend regression `linux read treats empty buffers as completed no-ops`; the final Zig test-runner groups reported 54/54 and 52/52 passed.

S4 quick matrix summary:

- `metadata.profile=quick`
- `metadata.git_revision=c979895847d7136bce83811e53314c3356fb5048`
- `metadata.os_platform=Linux-7.0.5-orbstack-00330-ge3df4e19b0a0-dirty-aarch64-with-glibc2.40`
- `metadata.zig_version=0.15.2`
- `metadata.backend_status=linux-io-uring-intended`
- `row_count=2`
- `rows_by_mode.memory=1`
- `rows_by_mode.persisted=1`

S4 `linux-io-uring --ops 1000` summary:

- `metadata.profile=linux-io-uring`
- `metadata.git_revision=c979895847d7136bce83811e53314c3356fb5048`
- `metadata.backend_status=linux-io-uring-intended`
- `row_count=24`
- `rows_by_mode.memory=12`
- `rows_by_mode.persisted=12`
- Summary JSON validated with `python3 -m json.tool`.

Representative post-remediation rows:

| Source | Mode | Ops | Value size | Batch size | Read API | Total ops/sec | Write ops/sec | Read ops/sec | Write p50/p95/p99 (us) | Read p50/p95/p99 (us) |
| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- | --- |
| S4 quick row 1 | persisted | 1,000 | 16 | 16 | `getInto` | 728,874.13 | 2,132,196.16 | 439,584.59 | 0.32 / 0.63 / 1.94 | 2.21 / 2.50 / 3.00 |
| S4 profile row 12 | persisted | 1,000 | 16 | 1 | `get` | 108,844.53 | 107,366.22 | 110,364.62 | 4.88 / 22.50 / 27.63 | 2.25 / 41.00 / 49.79 |
| S4 profile row 15 | persisted | 1,000 | 16 | 16 | `getInto` | 439,842.42 | 751,667.76 | 310,876.83 | 1.18 / 1.84 / 1.91 | 2.25 / 3.13 / 37.29 |
| S4 profile row 23 | persisted | 1,000 | 256 | 64 | `getInto` | 122,802.35 | 870,164.50 | 66,069.65 | 0.65 / 6.70 / 6.70 | 2.33 / 43.83 / 51.42 |

The S4 run confirms the optimized WAL write path is correct on Linux `io_uring`, but the cheap 1,000-op persisted throughput rows are noisy and lower than the earlier Ubuntu profile in some rows. Treat this as correctness and backend-status evidence for the optimization PRD, not a definitive Linux performance win/loss claim.

Persisted S4 `db_path` values and matching `.wal` files under `/tmp/phage-benchmark-matrix-*` were absent after the runner completed. Raw JSONL and summary JSON artifacts stayed under `/tmp` and were not committed.

### Compaction profile follow-up

A later compaction-specific S4 run verified the compaction benchmark/profile path on OrbStack `phage-linux` at git revision `7f1d25c8e2100309a0c33551fe515491aab524df` with `metadata.backend_status=linux-io-uring-intended`. The run used Zig `0.15.2`, host `Linux phage-linux 7.0.5-orbstack-00330-ge3df4e19b0a0-dirty #1 SMP PREEMPT Sun May 10 11:47:42 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux`, and a temporary native Linux clone at `/tmp/phage-s4-716/repo`.

Verification commands:

```sh
zig build test
zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-s4-716-direct-db > /tmp/phage-s4-716-direct.json
python3 -m json.tool /tmp/phage-s4-716-direct.json >/dev/null
bench/benchmark-matrix.sh --profile compaction --output /tmp/phage-s4-716-profile.jsonl
python3 -m json.tool /tmp/phage-s4-716-profile-summary.json >/dev/null
```

Results:

- Linux `zig build test` passed with `58 of 58 tests passed`.
- Direct compaction smoke: `operation_count=192`, `live_key_count=64`, `value_size=64`, `update_rounds=2`, `triggered=true`, `trigger_count=2`, `waste_ratio_before=0.496055`, `waste_ratio_after=0.0`, `file_size_before=9759`, `file_size_after=4918`, `file_size_reduction_bytes=9682`, `write_ops_per_sec=372874.18`, write p50/p95/p99 `1.83/2.79/33.25us`, trigger latency `34.00us`.
- Matrix compaction summary JSON: `metadata.profile=compaction`, `metadata.backend_status=linux-io-uring-intended`, `row_count=1`, `rows_by_mode.persisted=1`; representative row `operation_count=384`, `live_key_count=128`, `trigger_count=2`, waste `0.498017→0.0`, file size `19670→9874`, write p50/p95/p99 `1.88/2.63/16.25us`.
- Direct and matrix database, `.wal`, and `.compact.tmp` paths were absent after the run; raw JSON/JSONL/summary artifacts and the temporary clone were removed after extracting curated evidence.

See [Compaction benchmark and status evidence](2026-05-18-compaction-performance.md) for the full compaction-specific S4 table and artifact-hygiene details.

## Correctness blocker remediated on Linux

The initial Linux host resolved the missing-host blocker, but `zig build test` did not pass on the Linux `io_uring` backend path. The failing test was:

```text
write_ahead_log:recover_committed_empty_put_at_zero_offset
```

Observed failure path:

- `src/io/wal.zig:397` calls `store.get(key)` after WAL recovery of an empty value at data offset `0`.
- The read path reaches `src/root.zig` `readDataInto` / `getInto`.
- The Linux backend returned `IOUringError` from `src/io/backend.zig` `waitWithRing` after an `io_uring` completion reported a negative result.

Remediation card `t_c54e96cd` fixed the issue in `bc23f18` by returning an already-completed no-op for empty `io_uring` reads. The post-remediation S4 rerun above confirms the full Linux correctness gate is now green for current HEAD `c979895847d7136bce83811e53314c3356fb5048`.

## Reproduction runbook for future Linux verification

Run from a Linux host or VM that has Zig 0.15.x and supports `io_uring`:

```sh
cd /path/to/phage

git status --short --untracked-files=all
uname -a
zig version
zig build test

# Cheap Linux matrix smoke for audit/reviewer evidence.
bench/benchmark-matrix.sh --quick --output /tmp/phage-linux-io-uring-quick.jsonl
python3 -m json.tool /tmp/phage-linux-io-uring-quick-summary.json >/dev/null

# Fuller Linux io_uring profile. This covers memory and persisted rows across
# value sizes 16/256, batch sizes 1/16/64, and read APIs get/get-into.
bench/benchmark-matrix.sh --profile linux-io-uring --output /tmp/phage-linux-io-uring-matrix.jsonl
python3 -m json.tool /tmp/phage-linux-io-uring-matrix-summary.json >/dev/null
```

For a cheap follow-up smoke, keep the profile but override operations explicitly and record that override in the handoff:

```sh
bench/benchmark-matrix.sh --profile linux-io-uring --ops 1000 --output /tmp/phage-linux-io-uring-matrix-ops1000.jsonl
python3 -m json.tool /tmp/phage-linux-io-uring-matrix-ops1000-summary.json >/dev/null
```

## Expected artifacts

Keep raw artifacts under `/tmp` unless a follow-up ticket explicitly asks for a curated committed summary:

- `/tmp/phage-linux-io-uring-quick.jsonl`
- `/tmp/phage-linux-io-uring-quick-summary.json`
- `/tmp/phage-linux-io-uring-matrix.jsonl`
- `/tmp/phage-linux-io-uring-matrix-summary.json`

The summary JSON should include:

- `type=benchmark_summary`
- `metadata.profile=quick` for the quick smoke and `metadata.profile=linux-io-uring` for the fuller profile
- `metadata.os_platform` naming Linux and the kernel version
- `metadata.zig_version`
- `metadata.git_revision`
- `metadata.backend_status=linux-io-uring-intended`
- `row_count=2` for the quick smoke and `row_count=24` for the default linux-io-uring profile
- `rows_by_mode.memory=12` and `rows_by_mode.persisted=12` for the default linux-io-uring profile
- `best_total_ops_per_sec` populated with one benchmark row

Persisted row `db_path` values should be unique `/tmp/phage-benchmark-matrix-*` paths, and the runner should remove each store and `.wal` file after the row completes.

## Future rerun handoff checklist

For future Linux verification reruns, record:

1. `git_revision`, `uname -a`, `zig version`, and `metadata.backend_status`.
2. The exact quick and fuller profile commands, including any `--ops` override.
3. `zig build test` passing on Linux.
4. `python3 -m json.tool` validation for each summary JSON.
5. Representative persisted rows: at minimum one small value/batch row and one larger value or batch row with total ops/sec and p50/p95/p99 latency.
6. Final `git status --short --untracked-files=all`, explicitly confirming no generated database, WAL, log, JSONL, or summary artifacts are staged.

## Related documents

- [Benchmark matrix PRD](../prds/2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
- [WAL write-path optimization evidence](2026-05-18-wal-write-path-optimization.md)
- [Getting Started](../GETTING_STARTED.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
