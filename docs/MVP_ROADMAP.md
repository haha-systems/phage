# Phage MVP Roadmap

**Last Updated**: 2026-05-18
**Status**: Core storage, recovery, benchmark, benchmark matrix, protocol-command, server build/run, live command smoke, serialized multi-client server smoke, and server workflow docs are implemented for review

## Executive Summary

Phage's currently supported development surface is the Zig core key/value store, persistence/WAL layer, sharded index, metrics counters, protocol command execution tests, native benchmark runner, and explicit ZeroMQ server build/run/smoke steps. The overnight S1-S8 implementation/review pass verified core areas with `zig build test` and benchmark smokes; the server runtime PRD adds `phage-server`, `run-server`, `server-smoke`, and `server-sustained-smoke` workflows.

The ZeroMQ server source in `src/zserver.zig` contains structured lifecycle logging plus SIGINT/SIGTERM shutdown-state wiring. Runtime claims should distinguish between verified serialized multi-client REQ/REP behavior and unclaimed parallel command execution or throughput scaling.

## Current Status Assessment

### Strengths

- Core storage API supports `put`, `putBatch`, `get`, `getInto`, `delete`, WAL recovery, compaction coverage, and batch writes.
- WAL/recovery hardening covers committed WAL entries, corrupt tails, invalid operation tags, delete replay, and WAL-only/data-missing crash states.
- `zig build test` is the standard correctness gate and includes storage, protocol command, compaction, benchmark, metrics, and server-runtime unit tests.
- `zig build -Doptimize=ReleaseFast benchmark -- ...` is the supported local one-shot benchmark path, with human or JSON output, memory or persisted modes, configurable value/batch sizes, `get` vs `getInto` read-path selection, and a persisted `--profile compaction` smoke for update-heavy compaction evidence.
- `bench/benchmark-matrix.sh` runs repeatable quick/full/compaction benchmark profiles and emits JSON Lines rows plus a compact summary with git, Zig, OS/platform, profile, timestamp, and backend-status metadata.
- macOS POSIX fallback remains useful for development and tests while Linux `io_uring` remains the intended high-performance backend; the 2026-05-18 quick-profile fallback baseline is recorded under `docs/benchmarks/`.

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
| Native benchmark runner | Active | Supports cheap memory and persisted one-shot smoke runs through the `benchmark` build step. |
| Benchmark matrix workflow | Active / implemented for review | `bench/benchmark-matrix.sh --quick --output /tmp/phage-benchmark-matrix.jsonl` emits row-level JSON Lines and `/tmp/phage-benchmark-matrix-summary.json`; `--profile full` covers memory/persisted, batch sizes `1/16/64`, value sizes `16/256`, and `get`/`get-into` read APIs. Current macOS fallback quick baseline: memory `11.90M` total ops/sec, persisted `1.16M` total ops/sec; see [macOS POSIX-fallback benchmark baseline](benchmarks/2026-05-18-macos-fallback-baseline.md). |
| WAL write-path optimization evidence | Active / macOS and Linux evidence documented | The S3 evidence note records S1/S2 before/after persisted write rows for macOS POSIX fallback, with roughly 14–15% higher write throughput across batch sizes `1/16/64`; S4 now records post-optimization Linux `io_uring` correctness and cheap persisted rows. See [WAL write-path optimization evidence](benchmarks/2026-05-18-wal-write-path-optimization.md). |
| Benchmark output/reporting | Active / reviewed | Human output remains default for one-shot runs; `--json` emits machine-readable mode/count/value/batch/latency/throughput fields, and matrix summaries add reproducibility metadata without replacing one-shot JSON. |
| Compaction benchmark/status evidence | Active / macOS and Linux evidence documented | `--profile compaction` creates persisted update-heavy waste and reports live keys, update rounds, trigger count/status, waste ratio before/after, file-size reduction, latency, and throughput fields. S2 hardens failed inline compaction cleanup and clarifies that threshold compaction is inline rather than background. Current curated evidence separates macOS POSIX-fallback rows from S4 Linux `io_uring` verification rows; Linux direct and matrix compaction smokes recorded `backend_status=linux-io-uring-intended`, `triggered=true`, `trigger_count=2`, and waste reduced to `0.0`. See [compaction benchmark and status evidence](benchmarks/2026-05-18-compaction-performance.md). |
| Linux io_uring verification | Verified after remediation | OrbStack NixOS 25.11 arm64 passed Linux `zig build test` after `bc23f18` and the WAL clear optimization, including the prior `write_ahead_log:recover_committed_empty_put_at_zero_offset` failure. S4 quick/profile summaries record `metadata.backend_status=linux-io-uring-intended`, `row_count=2` quick, and `row_count=24` with `--profile linux-io-uring --ops 1000`; representative persisted rows are recorded in [Linux io_uring benchmark verification](benchmarks/2026-05-18-linux-io-uring-verification.md). |

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

# macOS/Linux: machine-readable one-shot output for automation
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json

# macOS/Linux: persisted update-heavy compaction smoke with machine-readable output
zig build -Doptimize=ReleaseFast benchmark -- 64 --profile compaction --mode persisted --value-size 64 --update-rounds 2 --read-api get-into --json --db-path /tmp/phage-mvp-roadmap-compaction

# macOS/Linux: cheap comparable matrix output for audits/reviews
bench/benchmark-matrix.sh --quick --output /tmp/phage-benchmark-matrix.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-summary.json >/dev/null

# macOS/Linux: cheap compaction-profile matrix row for compaction audits
bench/benchmark-matrix.sh --profile compaction --output /tmp/phage-compaction-profile.jsonl
python3 -m json.tool /tmp/phage-compaction-profile-summary.json >/dev/null

# Fuller comparable matrix profile; keep raw outputs in /tmp unless a ticket
# explicitly approves committing a small curated summary.
bench/benchmark-matrix.sh --profile full --output /tmp/phage-benchmark-matrix-full.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-full-summary.json >/dev/null
```

Backend note: macOS runs the POSIX fallback path. Linux is the target platform for `io_uring` fast-path performance. OrbStack NixOS now provides post-remediation Linux correctness and matrix evidence for the optimized WAL write path: Linux `zig build test` passes after `bc23f18`, and the quick/profile summaries report `metadata.backend_status=linux-io-uring-intended`; see [Linux io_uring benchmark verification](benchmarks/2026-05-18-linux-io-uring-verification.md) for representative rows, required commands, and artifact hygiene. The current macOS quick-profile fallback baseline is recorded in [macOS POSIX-fallback benchmark baseline](benchmarks/2026-05-18-macos-fallback-baseline.md). The current compaction evidence note records macOS POSIX-fallback compaction rows separately from S4 Linux `io_uring` compaction verification rows; see [compaction benchmark and status evidence](benchmarks/2026-05-18-compaction-performance.md).

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
- [WAL write-path optimization evidence](benchmarks/2026-05-18-wal-write-path-optimization.md)
- [Compaction benchmark and status evidence](benchmarks/2026-05-18-compaction-performance.md)
- [Linux io_uring benchmark verification runbook](benchmarks/2026-05-18-linux-io-uring-verification.md)
