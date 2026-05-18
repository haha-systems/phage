# Linux io_uring benchmark verification runbook

Date: 2026-05-18
Status: blocked waiting for a Linux host with io_uring support
PRD slice: S4 Linux io_uring verification path

## Current worker capability check

This S4 worker could not collect Linux io_uring performance evidence because the live worker is macOS, not Linux.

Evidence collected from the worker environment:

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

Zig backend source also selects io_uring only when the target OS is Linux:

```zig
pub const default_kind: BackendKind = if (builtin.os.tag == .linux) .linux_iouring else .posix;
```

Because this host reports `Darwin` and the matrix metadata reports `backend_status=macos-posix-fallback`, any persisted numbers from this worker would be POSIX fallback results and must not be used as Linux io_uring evidence.

## Missing capability

Required capability: a Linux worker/host that can build this repository with Zig 0.15.x and run Phage persisted benchmarks through the Linux-selected backend. The host should expose a kernel/filesystem combination where `std.os.linux.IoUring.init_params` succeeds for Phage's `src/io/backend.zig` backend.

Do not run the Linux profile on macOS and do not relabel `backend_status=macos-posix-fallback` output as Linux evidence.

## Commands to run on the Linux host

Run from the repository root on the Linux host:

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

If the full profile is too expensive for the first Linux smoke, keep the profile but override operations explicitly and record that override in the handoff:

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

## Suggested Linux handoff summary

When a Linux host run is complete, the follow-up handoff should record:

1. `git_revision`, `uname -a`, `zig version`, and `metadata.backend_status`.
2. The exact quick and fuller profile commands, including any `--ops` override.
3. `python3 -m json.tool` validation for each summary JSON.
4. Representative persisted rows: at minimum one small value/batch row and one larger value or batch row with total ops/sec and p50/p95/p99 latency.
5. Final `git status --short --untracked-files=all`, explicitly confirming no generated database, WAL, log, JSONL, or summary artifacts are staged.

## Related documents

- [Benchmark matrix PRD](../prds/2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
- [Getting Started](../GETTING_STARTED.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
