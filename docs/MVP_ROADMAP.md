# Phage MVP Roadmap

**Last Updated**: 2026-05-18
**Status**: Core storage, recovery, benchmark, protocol-command, and runtime-readiness slices reviewed; ZeroMQ server build/run wiring remains deferred

## Executive Summary

Phage's currently supported development surface is the Zig core key/value store, persistence/WAL layer, sharded index, metrics counters, protocol command execution tests, and native benchmark runner. The overnight S1-S8 implementation/review pass verified these areas with `zig build test` and benchmark smokes.

The ZeroMQ server source remains in `src/zserver.zig` and now contains structured lifecycle logging plus SIGINT/SIGTERM shutdown-state wiring, but it is not exposed by the default Zig build graph. User-facing MVP claims should therefore distinguish between verified core/protocol behavior and source-present server behavior that still needs build/runtime integration.

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
| ZeroMQ server build | Deferred | `zig build --help` lists `install`, `uninstall`, `benchmark`, and `test`; there is no supported `run` step. `src/zserver.zig` remains source-present for later wiring. |
| Server shutdown/logging source | Source-present / partially unit-tested | Shutdown state is unit-tested and wired into the server loop; live signal, multi-client, and ZeroMQ smoke verification remain blocked until build wiring is restored. |
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
| Wire server into build graph | TODO | Needs a dedicated server/build slice; do not claim `zig build run` support until present. |
| Add live server smoke | TODO | Should happen once server build support and ZeroMQ dependency wiring are restored. |

### Phase 3: Production readiness

| Task | Status | Notes |
|------|--------|-------|
| Runtime metrics | Active / reviewed | Core storage exposes `store.metrics.snapshot()` for read/write/delete counts, error counts, and total operation latencies. |
| Structured logging | Source-present / documented | Server source logs start, bind, receive-error, and shutdown paths with key/value-style messages. |
| Graceful shutdown | Source-present / unit-tested helper | `src/server/runtime.zig` covers SIGINT/SIGTERM shutdown state and `src/zserver.zig` checks it, but live server smoke remains blocked by missing build graph support. |
| Sustained smoke/leak checks | Documented core smoke | Use `zig build test` plus `zig build -Doptimize=ReleaseFast benchmark -- 5000 --mode memory --value-size 16 --batch-size 64` for the supported no-artifact smoke path. |
| Multi-client behavior | TODO | Live ZeroMQ runtime verification is still blocked until the server is restored to the build graph. |

## Verification commands

Minimum local correctness check:

```sh
git status --short --untracked-files=all
zig build test
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
# Current default steps are install, uninstall, benchmark, and test; no supported run/server step is listed.
```

## Documentation rules for MVP claims

- Do not claim a supported server launch command until the build graph exposes one.
- Do not require the external Demon client for repository-local workflows.
- Describe `KEYS` as regex-style matching with special `*` all-key behavior.
- Describe protocol `BENCHMARK` as separate from the native benchmark runner and mutating the active store.
- Prefer memory-mode benchmark examples for smoke checks that should leave no filesystem artifacts.
- Use explicit `/tmp/...` `--db-path` values for persisted benchmark examples.
- Keep generated database, WAL, benchmark-store, and log artifacts out of commits.

## Related documents

- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
