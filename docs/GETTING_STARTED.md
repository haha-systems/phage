# Getting Started with Phage

## What is Phage?

Phage is a Zig key/value store with:

- Persistent storage with write-ahead logging and recovery paths.
- A sharded in-memory index.
- Allocation-owning and caller-buffer read APIs (`get` and `getInto`).
- Basic in-process metrics for storage operation counts, errors, and total latency.
- A native benchmark runner for local performance checks, plus a repository-local matrix runner for comparable JSONL/summary artifacts.
- Protocol and a supported ZeroMQ server workflow under `src/protocol/` and `src/zserver.zig`.
- Linux `io_uring` as the intended high-performance backend, with a POSIX fallback that lets tests and memory/persisted benchmark smokes run on macOS.

## Prerequisites

- Zig 0.15.x (the current local project has been verified with Zig 0.15.2).
- macOS or Linux for tests and the native benchmark runner.
- Server build/run/smoke steps require the pinned Zig 0.15-compatible `zimq` package from `build.zig.zon` and a working ZeroMQ/libzmq environment. Use `zig build --fetch` when dependencies need to be fetched before offline builds.
- Linux for final measurements of the intended `io_uring` backend fast path.

## Build and test

```sh
cd /path/to/phage
zig build
zig build test
```

Current `build.zig` steps are:

```sh
zig build --help
# Steps include: install, uninstall, benchmark, test, phage-server, run-server, server-smoke, server-sustained-smoke
```

## Run local benchmarks

The supported local performance path is the native benchmark runner. It does not require the ZeroMQ server.

```sh
# Fast in-memory smoke without persistence artifacts
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16

# Persisted smoke with an explicit disposable path
zig build -Doptimize=ReleaseFast benchmark -- 1000 --value-size 16 --batch-size 16 --db-path /tmp/phage-getting-started-bench

# Buffered read-path smoke using getInto instead of allocating get
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 256 --batch-size 64 --read-api get-into

# Machine-readable one-shot output for automation
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json

# Persisted update-heavy compaction smoke; records trigger/waste/file-size fields
zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-getting-started-compaction

# Cheap benchmark matrix smoke: writes JSON Lines rows and a compact summary JSON
bench/benchmark-matrix.sh --quick --output /tmp/phage-benchmark-matrix.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-summary.json >/dev/null

# Cheap compaction matrix smoke: one persisted update-heavy row plus summary JSON
bench/benchmark-matrix.sh --profile compaction --output /tmp/phage-compaction-profile.jsonl
python3 -m json.tool /tmp/phage-compaction-profile-summary.json >/dev/null

# Fuller comparable matrix profile; keep raw outputs in /tmp unless a ticket
# explicitly approves committing a small curated summary.
bench/benchmark-matrix.sh --profile full --output /tmp/phage-benchmark-matrix-full.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-full-summary.json >/dev/null
```

Benchmark options currently include:

| Option | Meaning |
|--------|---------|
| positional `OPS` | Number of write/read operations for the standard profile; live-key count for `--profile compaction`; default is `10000`. |
| `--mode persisted|memory` | `persisted` uses Phage storage; `memory` uses a HashMap baseline without filesystem or WAL I/O. Default is `persisted`. |
| `--profile standard|compaction` | `standard` runs ordinary put/read operations; `compaction` runs a persisted update-heavy workload and reports compaction trigger, waste-ratio, file-size, latency, and throughput fields. Default is `standard`. |
| `--value-size BYTES` | Value payload size; default is `16`. |
| `--batch-size N` | Number of writes to group before waiting; default is `1`. |
| `--read-api get|get-into` | Selects allocating `get` or caller-buffer `getInto` for reads. Default is `get`. |
| `--update-rounds N` | Number of update passes after the initial live-key load for `--profile compaction`; default is `2`. |
| `--buffered-reads` | Alias for `--read-api get-into`. |
| `--db-path PATH` | Database path for persisted mode; default is `phage_benchmark_store`. Prefer `/tmp/...` in docs/smokes. |
| `--reuse` | Reuse an existing persisted database instead of deleting it first. |
| `--json` | Emit machine-readable JSON instead of human text. |

The protocol `BENCHMARK` command is separate from this native benchmark runner. It runs through the server command path and writes benchmark keys into the active store; use the native benchmark command above for reproducible local checks.

### Benchmark matrix workflow

Use `bench/benchmark-matrix.sh` when you need comparable row-level results across a small matrix. The quick profile is intended for reviewer and final-audit smoke checks; it runs one memory row and one persisted row with `--read-api get-into`, value size `16`, batch size `16`, and 1,000 operations per row. Persisted rows use unique temporary database paths and the runner removes generated store/WAL files after each row. Keep raw JSONL/summary outputs under `/tmp` unless a ticket explicitly approves committing a small curated summary.

```sh
# Cheap local matrix smoke
bench/benchmark-matrix.sh --quick --output /tmp/phage-benchmark-matrix.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-summary.json >/dev/null

# Fuller profile covering memory/persisted, batch sizes 1/16/64,
# value sizes 16/256, and get/get-into read APIs.
bench/benchmark-matrix.sh --profile full --output /tmp/phage-benchmark-matrix-full.jsonl

# Linux runbook profile: run only on a Linux host when collecting io_uring evidence.
bench/benchmark-matrix.sh --profile linux-io-uring --output /tmp/phage-linux-io-uring-matrix.jsonl
```

Matrix row JSON Lines include stable automation fields from the one-shot benchmark (`mode`, `operation_count`, `value_size`, `batch_size`, `read_api`, `throughput`, and `latency_us`) plus `type`, `row_index`, `profile`, `backend_status`, `git_revision`, `os_platform`, `zig_version`, and `timestamp`. Compaction-profile rows additionally include `workload_profile=compaction`, `live_key_count`, `update_rounds`, and a `compaction` object with trigger, waste-ratio, and file-size fields. The companion `*-summary.json` records the same run metadata, row count, row counts by mode, and the row with the best `total_ops_per_sec` when total throughput exists. Treat `command` and the raw platform string as informational metadata because they can vary by shell or machine.

### Platform notes

- macOS uses the POSIX fallback backend. It is suitable for correctness tests and local smoke checks, including persisted smokes with an explicit `/tmp/...` path. The current quick-profile fallback baseline is recorded in [macOS POSIX-fallback benchmark baseline](benchmarks/2026-05-18-macos-fallback-baseline.md). The macOS compaction-profile evidence is recorded separately from Linux in [compaction benchmark and status evidence](benchmarks/2026-05-18-compaction-performance.md). Do not treat macOS POSIX-fallback rows as Linux `io_uring` evidence.
- Linux is the intended high-performance target for the `io_uring` backend. The current Linux verification note records OrbStack Linux evidence after remediation: Kanban card `t_c54e96cd` and commit `bc23f18` fixed the WAL empty-read path, the S4 WAL rerun verified Linux `zig build test`, quick matrix evidence, and a cheap `linux-io-uring --ops 1000` profile with `metadata.backend_status=linux-io-uring-intended`, and the S4 compaction rerun verified direct and matrix compaction smokes with `backend_status=linux-io-uring-intended`, `triggered=true`, `trigger_count=2`, and waste reduced to `0.0`; see the [Linux io_uring benchmark verification note](benchmarks/2026-05-18-linux-io-uring-verification.md) for commands, representative rows, and reproduction guidance.
- Memory-mode benchmark examples are portable and avoid generated database/WAL artifacts.

## Server/protocol status

`src/zserver.zig` contains a ZeroMQ REP server implementation with command-line options for port, database path, and requested log level. The supported server workflow uses explicit `phage-server` and `run-server` build steps rather than the default `zig build run` step. Use explicit `/tmp/...` database paths for manual runs and smoke runs so generated store/WAL files stay disposable.

```sh
# Build the server executable
zig build phage-server

# Print server help without opening a socket or database
zig build run-server -- --help

# Start a local server with a disposable store path; press Ctrl-C to stop
zig build run-server -- --db-path /tmp/phage-getting-started-server --port 5555

# Live MVP command smoke over ZeroMQ
zig build server-smoke -- --db-path /tmp/phage-server-smoke

# Bounded repeated multi-client smoke over ZeroMQ
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100
```

Runtime readiness notes:

- `src/server/runtime.zig` provides the server shutdown state used by `src/zserver.zig` for SIGINT/SIGTERM handling. The sustained server smoke sends SIGTERM after repeated checked requests and asserts that the shutdown log includes read/write/delete and error counters.
- Lifecycle logs use structured key/value-style messages for server start, bind, receive errors, and shutdown.
- Core storage exposes `store.metrics.snapshot()` with read/write/delete operation counts, error counts, and accumulated latency nanoseconds. `putBatch` records one write per key/value pair.
- Verified client model: multiple ZeroMQ REQ clients can connect and complete repeated request/reply commands, but the server uses a single REP loop that serializes receive/execute/send handling. The current smoke does not claim parallel command execution or throughput scaling with client count.

The parser accepts these commands:

```text
SET key value
GET key
DELETE key
DEL key
KEYS pattern
PING
BENCHMARK operations
```

Protocol notes:

- Commands are case-insensitive.
- Arguments are whitespace-delimited single tokens.
- Quoted values and values containing spaces are not supported.
- `KEYS *` matches all keys.
- Other `KEYS` patterns use regex-style matching; use `user:.*` rather than shell-glob syntax when matching prefixes.
- `BENCHMARK operations` accepts operation counts from `1` to `1_000_000` and mutates the active store.

Example command transcript for a server/client:

```text
PING
# PONG

SET greeting hello
# OK

GET greeting
# hello

KEYS *
# greeting

DELETE greeting
# OK
```

## Sustained smoke/readiness checks

Use the full test suite plus the bounded live sustained server smoke before making server runtime-readiness claims:

```sh
zig build test
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100
```

The sustained server smoke starts the built server, opens multiple REQ clients, sends repeated checked commands from each client, captures the shutdown metrics log line, and removes `/tmp` store/WAL artifacts. It verifies serialized multi-client REQ/REP behavior, not parallel command execution.

## Current limitations

- Server build/run/smoke steps require ZeroMQ/`zimq` dependencies; core tests and the native benchmark runner do not start a live network server.
- Server command execution is serialized through a single ZeroMQ REP loop; multi-client smokes verify request/reply interoperability across multiple client connections, not concurrent in-process store access.
- The old external Demon client examples are not part of this repository and are not required for the supported test/benchmark workflow.
- Server log-level configuration is parsed and printed, but Zig log filtering is still compile-time constrained.

## Troubleshooting

### `zig build run` fails

The server workflow uses explicit build steps rather than the default `run` step. Use `zig build run-server -- --help` for server help, `zig build server-smoke -- --db-path /tmp/phage-server-smoke` for MVP command smoke, and `zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100` for repeated multi-client smoke.

### Server dependency fetch or link errors

The core library, tests, and native benchmark runner are independent of a live server, but server steps need the pinned `zimq` package and a working ZeroMQ/libzmq environment. Run `zig build --fetch` if the Zig package cache is empty, then rerun the server step. If linking fails, check that ZeroMQ/libzmq is installed for your platform.

### Benchmark artifacts appear locally

Use memory mode for artifact-free smokes. For persisted smokes, pass an explicit temporary `--db-path` and avoid staging generated `.db`, `.wal`, or benchmark-store artifacts.

The default persisted benchmark path is `phage_benchmark_store`. That local artifact is intentionally ignored by `.gitignore`, but generated files should still be deleted when no longer useful.

### KEYS pattern surprises

Use `KEYS *` for all keys. For prefixes, prefer regex-style patterns such as `KEYS user:.*`.

## Related documents

- [API Reference](API_REFERENCE.md)
- [MVP Roadmap](MVP_ROADMAP.md)
- [Compaction benchmark and status evidence](benchmarks/2026-05-18-compaction-performance.md)
- [Linux io_uring benchmark verification runbook](benchmarks/2026-05-18-linux-io-uring-verification.md)
