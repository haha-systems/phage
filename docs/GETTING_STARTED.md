# Getting Started with Phage

## What is Phage?

Phage is a Zig key/value store with:

- Persistent storage with write-ahead logging and recovery paths.
- A sharded in-memory index.
- Allocation-owning and caller-buffer read APIs (`get` and `getInto`).
- Basic in-process metrics for storage operation counts, errors, and total latency.
- A native benchmark runner for local performance checks.
- Protocol and a supported ZeroMQ server workflow under `src/protocol/` and `src/zserver.zig`.
- Linux `io_uring` as the intended high-performance backend, with a POSIX fallback that lets tests and memory/persisted benchmark smokes run on macOS.

## Prerequisites

- Zig 0.15.x (the current local project has been verified with Zig 0.15.2).
- macOS or Linux for tests and the native benchmark runner.
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

# Machine-readable output for automation
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json
```

Benchmark options currently include:

| Option | Meaning |
|--------|---------|
| positional `OPS` | Number of write/read operations; default is `10000`. |
| `--mode persisted|memory` | `persisted` uses Phage storage; `memory` uses a HashMap baseline without filesystem or WAL I/O. Default is `persisted`. |
| `--value-size BYTES` | Value payload size; default is `16`. |
| `--batch-size N` | Number of writes to group before waiting; default is `1`. |
| `--read-api get|get-into` | Selects allocating `get` or caller-buffer `getInto` for reads. Default is `get`. |
| `--buffered-reads` | Alias for `--read-api get-into`. |
| `--db-path PATH` | Database path for persisted mode; default is `phage_benchmark_store`. Prefer `/tmp/...` in docs/smokes. |
| `--reuse` | Reuse an existing persisted database instead of deleting it first. |
| `--json` | Emit machine-readable JSON instead of human text. |

The protocol `BENCHMARK` command is separate from this native benchmark runner. It runs through the server command path and writes benchmark keys into the active store; use the native benchmark command above for reproducible local checks.

### Platform notes

- macOS uses the POSIX fallback backend. It is suitable for correctness tests and local smoke checks, including persisted smokes with an explicit `/tmp/...` path.
- Linux is the intended high-performance target for the `io_uring` backend. Linux-only backend changes should still keep macOS tests green, but final `io_uring` performance claims need a Linux host.
- Memory-mode benchmark examples are portable and avoid generated database/WAL artifacts.

## Server/protocol status

`src/zserver.zig` contains a ZeroMQ REP server implementation with command-line options for port, database path, and requested log level. Use explicit `/tmp/...` database paths for smoke runs so generated store/WAL files stay disposable.

```sh
# Build the server executable
zig build phage-server

# Print server help without opening a socket or database
zig build run-server -- --help

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

- Server command execution is serialized through a single ZeroMQ REP loop; multi-client smokes verify request/reply interoperability across multiple client connections, not concurrent in-process store access.
- The old external Demon client examples are not part of this repository and are not required for the supported test/benchmark workflow.
- Server log-level configuration is parsed and printed, but Zig log filtering is still compile-time constrained.

## Troubleshooting

### `zig build run` fails

The server workflow uses explicit build steps rather than the default `run` step. Use `zig build run-server -- --help` for server help, `zig build server-smoke -- --db-path /tmp/phage-server-smoke` for MVP command smoke, and `zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100` for repeated multi-client smoke.

### Benchmark artifacts appear locally

Use memory mode for artifact-free smokes. For persisted smokes, pass an explicit temporary `--db-path` and avoid staging generated `.db`, `.wal`, or benchmark-store artifacts.

The default persisted benchmark path is `phage_benchmark_store`. That local artifact is intentionally ignored by `.gitignore`, but generated files should still be deleted when no longer useful.

### KEYS pattern surprises

Use `KEYS *` for all keys. For prefixes, prefer regex-style patterns such as `KEYS user:.*`.

## Related documents

- [API Reference](API_REFERENCE.md)
- [MVP Roadmap](MVP_ROADMAP.md)
