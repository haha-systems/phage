# Getting Started with Phage

## What is Phage?

Phage is a Zig key/value store with:

- Persistent storage with write-ahead logging and recovery paths.
- A sharded in-memory index.
- A native benchmark runner for local performance checks.
- Protocol and ZeroMQ server source code under `src/protocol/` and `src/zserver.zig`.
- Linux `io_uring` as the intended high-performance backend, with a POSIX fallback that lets tests and memory/persisted benchmark smokes run on macOS.

## Prerequisites

- Zig 0.15.x (the current local project has been verified with Zig 0.15.2).
- macOS or Linux for tests and the native benchmark runner.
- Linux for the intended `io_uring` backend performance target.

## Build and test

```sh
cd /path/to/phage
zig build
zig build test
```

Current `build.zig` steps are:

```sh
zig build --help
# Steps include: install, uninstall, benchmark, test
```

There is currently no supported `zig build run` server step in the default build graph.

## Run a local benchmark

The supported local performance path is the native benchmark runner:

```sh
# Fast in-memory smoke without persistence artifacts
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16

# Persisted smoke with an explicit disposable path
zig build -Doptimize=ReleaseFast benchmark -- 1000 --value-size 16 --batch-size 16 --db-path /tmp/phage-getting-started-bench
```

The protocol `BENCHMARK` command is separate from this native benchmark runner. It runs through the server command path and writes benchmark keys into the active store; use the native benchmark command above for reproducible local checks.

## Server/protocol status

`src/zserver.zig` contains a ZeroMQ REP server implementation with command-line options for port, database path, and requested log level. It is not currently installed by the default build graph, so the examples below document the protocol behavior rather than a copy-paste-ready server launch workflow.

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

Example command transcript for a server/client once the server executable is wired:

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

## Current limitations

- The ZeroMQ server is source-present but not exposed as a default `zig build` run/install artifact.
- The old external Demon client examples are not part of this repository and are not required for the supported test/benchmark workflow.
- Multi-client behavior, graceful shutdown, and production runtime observability are tracked as later production-readiness work.
- Server log-level configuration is parsed and printed, but Zig log filtering is still compile-time constrained.

## Troubleshooting

### `zig build run` fails

This is expected right now: the default build graph has no `run` step. Use `zig build test` for correctness and `zig build ... benchmark` for benchmark smokes.

### Benchmark artifacts appear locally

Use explicit temporary `--db-path` values for persisted benchmark smoke runs and avoid staging generated `.db`, `.wal`, or benchmark-store artifacts.

### KEYS pattern surprises

Use `KEYS *` for all keys. For prefixes, prefer regex-style patterns such as `KEYS user:.*`.

## Related documents

- [API Reference](API_REFERENCE.md)
- [MVP Roadmap](MVP_ROADMAP.md)
