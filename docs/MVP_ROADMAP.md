# Phage MVP Roadmap

**Last Updated**: 2026-05-18
**Status**: Core storage, recovery, benchmark, protocol-command, server build/run, live command smoke, serialized multi-client server smoke, and server workflow docs are implemented for review

## Executive Summary

Phage's currently supported development surface is the Zig core key/value store, persistence/WAL layer, sharded index, metrics counters, protocol command execution tests, native benchmark runner, and explicit ZeroMQ server build/run/smoke steps. The overnight S1-S8 implementation/review pass verified core areas with `zig build test` and benchmark smokes; the server runtime PRD adds `phage-server`, `run-server`, `server-smoke`, and `server-sustained-smoke` workflows.

The ZeroMQ server source in `src/zserver.zig` contains structured lifecycle logging plus SIGINT/SIGTERM shutdown-state wiring. Runtime claims should distinguish between verified serialized multi-client REQ/REP behavior and unclaimed parallel command execution or throughput scaling.

## Current Status Assessment

### Strengths

- Core storage API supports `put`, `putBatch`, `get`, `getInto`, `delete`, WAL recovery, compaction coverage, and batch writes.
- WAL/recovery hardening covers committed WAL entries, corrupt tails, invalid operation tags, delete replay, and WAL-only/data-missing crash states.
- `zig build test` is the standard correctness gate and includes storage, protocol command, compaction, benchmark, metrics, and server-runtime unit tests.
- `zig build -Doptimize=ReleaseFast benchmark -- ...` is the supported local benchmark path, with human or JSON output, memory or persisted modes, configurable value/batch sizes, and `get` vs `getInto` read-path selection.
- macOS POSIX fallback remains useful for development and tests while Linux `io_uring` remains the intended high-performance backend.

### Protocol/server status

| Area | Status | Notes |
|------|--------|-------|
| Protocol parser | Implemented / tested directly | Parser accepts `SET`, `GET`, `DELETE`/`DEL`, `KEYS`, `PING`, and `BENCHMARK`; malformed input, missing args, and benchmark bounds have focused coverage. |
| Command execution smoke | Implemented / unit-tested | `zig build test` covers deterministic execution/response mapping for `PING`, `SET`, `GET`, `DELETE`/`DEL`, `KEYS`, and `BENCHMARK 1`. |
| KEYS command | Implemented in store/protocol path | `KEYS *` matches all; other patterns are regex-style (for example `user:.*`). |
| BENCHMARK command | Implemented separately from native runner | Protocol benchmark mutates the active store and does not delegate to `src/benchmark.zig`. Use the native benchmark step for reproducible measurements. |
| ZeroMQ server build/run | Implemented / explicit build steps | `zig build --help` lists `phage-server` and `run-server`; manual runs should use `zig build run-server -- --db-path /tmp/phage-roadmap-server --port 5555`; server build/run depends on the pinned Zig 0.15-compatible `zimq` dependency and a working ZeroMQ/libzmq environment. |
| Live server smoke | Implemented / explicit smoke step | `zig build server-smoke -- --db-path /tmp/phage-server-smoke` starts the built server and verifies the MVP command set over ZeroMQ. |
| Server shutdown/logging source | Implemented / smoke-verified | Shutdown state is unit-tested and wired into the server loop; `server-sustained-smoke` asserts the shutdown metrics log line after repeated checked requests. |
| External Demon client | Not part of this repository | User-facing docs should not require it for the supported workflow. |

## MVP Roadmap

### Phase 1: Core safety and measurement baseline

| Task | Status | Notes |
|------|--------|-------|
| Core storage tests | Active / reviewed | Run with `zig build test`. |
| WAL path ownership and test artifact isolation | Complete for current slice | Store-owned WAL path lifetime and ignored test artifact paths were reviewed in S1. |
| WAL/recovery hardening | Complete for current slice | Empty values at data offset 0, invalid op tags, delete replay, helper-based WAL clearing, and missing-data WAL replay are covered. |
| Native benchmark runner | Active | Supports cheap memory and persisted smoke runs through the `benchmark` build step. |
| Benchmark output/reporting | Active / reviewed | Human output remains default; `--json` emits machine-readable mode/count/value/batch/latency/throughput fields. |

### Phase 2: Protocol and server MVP

| Task | Status | Notes |
|------|--------|-------|
| Align command parser errors | Complete for current slice | Missing args, malformed extra args, empty keys/patterns, and benchmark bounds are covered. |
| Keep KEYS behavior truthful | Complete for current slice | Docs describe regex-style patterns and special `*` behavior. |
| Document BENCHMARK split | Complete for current slice | Protocol `BENCHMARK` is separate from native benchmarking and mutates the active store. |
| Command execution smoke | Active / reviewed | Unit coverage exercises command execution and `payloadToString` response mapping for the MVP command set. |
| Wire server into build graph | Active / reviewed | Use `zig build phage-server`, `zig build run-server -- --help`, or `zig build run-server -- --db-path /tmp/phage-roadmap-server --port 5555`; the default `zig build run` step is still not the server workflow. |
| Add live server smoke | Active / reviewed | Use `zig build server-smoke -- --db-path /tmp/phage-server-smoke` for MVP command coverage; it requires server ZeroMQ/`zimq` dependencies but not the external Demon client. |

### Phase 3: Production readiness

| Task | Status | Notes |
|------|--------|-------|
| Runtime metrics | Active / reviewed | Core storage exposes `store.metrics.snapshot()` for read/write/delete counts, error counts, and total operation latencies. |
| Structured logging | Source-present / documented | Server source logs start, bind, receive-error, and shutdown paths with key/value-style messages. |
| Graceful shutdown | Active / smoke-verified | `src/server/runtime.zig` covers SIGINT/SIGTERM shutdown state and `src/zserver.zig` checks it; sustained smoke captures `server lifecycle event=shutdown` metrics after SIGTERM. |
| Sustained smoke/leak checks | Active / explicit server smoke | Use `zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100` for a bounded live repeated-request smoke that cleans `/tmp` store/WAL files. |
| Multi-client behavior | Active / serialized model verified | Multiple ZeroMQ REQ clients can connect and complete repeated request/reply commands; the single REP loop serializes command execution and does not claim parallel store access. |

## Verification commands

Minimum local correctness check:

```sh
git status --short --untracked-files=all
zig build test
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100
```

`zig fmt src build.zig` remains the formatting gate when Zig source files are touched. Docs-only changes do not need a formatting run beyond Markdown review.

Cheap benchmark smoke examples:

```sh
# macOS/Linux: no filesystem artifacts, good for quick local smoke checks
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16

# macOS/Linux: persisted path smoke through the POSIX fallback on macOS and native backend selection on Linux
zig build -Doptimize=ReleaseFast benchmark -- 1000 --value-size 16 --batch-size 16 --db-path /tmp/phage-mvp-roadmap-bench

# macOS/Linux: machine-readable output for automation
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json
```

Backend note: macOS runs the POSIX fallback path. Linux is the target platform for `io_uring` fast-path performance and should be used for final Linux backend benchmarking.

Server status check:

```sh
zig build --help
zig build run-server -- --help
# Server steps include phage-server, run-server, server-smoke, and server-sustained-smoke.
# To start a manual server, use a disposable path: zig build run-server -- --db-path /tmp/phage-roadmap-server --port 5555
```

## Documentation rules for MVP claims

- Use explicit server workflow names: `phage-server`, `run-server`, `server-smoke`, and `server-sustained-smoke`; do not imply that the default `zig build run` step launches the server.
- State that server build/run/smoke steps require the pinned `zimq` package and a working ZeroMQ/libzmq environment, while core tests and native benchmark smokes do not start a live network server.
- Describe the verified server runtime model as serialized multi-client REQ/REP handling, not parallel command execution.
- Do not require the external Demon client for repository-local workflows.
- Describe `KEYS` as regex-style matching with special `*` all-key behavior.
- Describe protocol `BENCHMARK` as separate from the native benchmark runner and mutating the active store.
- Prefer memory-mode benchmark examples for smoke checks that should leave no filesystem artifacts.
- Use explicit `/tmp/...` `--db-path` values for persisted benchmark examples.
- Keep generated database, WAL, benchmark-store, and log artifacts out of commits.

## Related documents

- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
