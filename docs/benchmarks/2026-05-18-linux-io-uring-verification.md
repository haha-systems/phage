# Linux io_uring benchmark verification

Date: 2026-05-18
Status: Linux benchmark evidence collected via OrbStack; final all-green Linux correctness gate deferred to remediation card `t_c54e96cd`
PRD slice: S4 Linux io_uring verification path

## Status summary

The original S4 worker ran on macOS and correctly refused to treat POSIX-fallback numbers as Linux `io_uring` evidence. A follow-up approved Linux execution path became available through OrbStack, and the Linux benchmark matrix workflow completed both the quick smoke and a fuller `linux-io-uring` profile on an Ubuntu 24.04 arm64 machine.

Linux status for this slice: `deferred with a remediation card`.

Why deferred instead of fully green: the Linux matrix benchmark evidence exists and reports `metadata.backend_status=linux-io-uring-intended`, but `zig build test` on the same Linux/OrbStack environment exposed an `io_uring` backend failure in WAL empty-value recovery. That correctness gap is tracked by Kanban remediation card `t_c54e96cd`.

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

## Correctness blocker discovered on Linux

The Linux host resolved the missing-host blocker, but `zig build test` did not pass on the Linux `io_uring` backend path. The failing test was:

```text
write_ahead_log:recover_committed_empty_put_at_zero_offset
```

Observed failure path:

- `src/io/wal.zig:397` calls `store.get(key)` after WAL recovery of an empty value at data offset `0`.
- The read path reaches `src/root.zig` `readDataInto` / `getInto`.
- The Linux backend returns `IOUringError` from `src/io/backend.zig` `waitWithRing` after an `io_uring` completion reports a negative result.

This is tracked separately as remediation card `t_c54e96cd`: fix the Linux `io_uring` WAL empty-value recovery test failure. Until that card is resolved, Linux benchmark numbers should be treated as useful performance evidence for the matrix workflow, not as proof that the full Linux correctness gate is green.

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

## Suggested final handoff summary

When the Linux correctness remediation is fixed, the final handoff should record:

1. `git_revision`, `uname -a`, `zig version`, and `metadata.backend_status`.
2. The exact quick and fuller profile commands, including any `--ops` override.
3. `zig build test` passing on Linux.
4. `python3 -m json.tool` validation for each summary JSON.
5. Representative persisted rows: at minimum one small value/batch row and one larger value or batch row with total ops/sec and p50/p95/p99 latency.
6. Final `git status --short --untracked-files=all`, explicitly confirming no generated database, WAL, log, JSONL, or summary artifacts are staged.

## Related documents

- [Benchmark matrix PRD](../prds/2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
- [Getting Started](../GETTING_STARTED.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
