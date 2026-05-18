# Phage MVP Roadmap

**Last Updated**: 2026-05-18
**Status**: Core storage and native benchmark path active; server/protocol MVP alignment in progress

## Executive Summary

Phage's core key/value store, persistence/WAL code, sharded index, and native benchmark runner are the currently supported development surface. Protocol parsing and a ZeroMQ server implementation exist, but the server is not wired into the default Zig build graph today. MVP work should therefore distinguish between verified core/benchmark behavior and source-present server behavior that still needs build/runtime hardening.

## Current Status Assessment

### Strengths

- Core storage API supports put/get/delete, WAL recovery paths, compaction work, and batch writes.
- `zig build test` is the standard correctness gate.
- `zig build -Doptimize=ReleaseFast benchmark -- ...` is the supported local benchmark path.
- macOS POSIX fallback remains useful for development and tests while Linux `io_uring` remains the intended high-performance backend.

### Protocol/server status

| Area | Status | Notes |
|------|--------|-------|
| Protocol parser | In progress / tested directly | Parser accepts `SET`, `GET`, `DELETE`/`DEL`, `KEYS`, `PING`, and `BENCHMARK`; malformed input and missing arguments have focused parser coverage. |
| KEYS command | Implemented in store/protocol path | `KEYS *` matches all; other patterns are regex-style (for example `user:.*`). |
| PING command | Implemented | Returns `PONG`. |
| BENCHMARK command | Implemented separately from native runner | Protocol benchmark mutates the active store and does not delegate to `src/benchmark.zig`. Use the native benchmark step for reproducible measurements. |
| ZeroMQ server build | Not supported by default build graph | `zig build --help` lists `install`, `test`, and `benchmark`; there is no `run` step. `src/zserver.zig` remains source-present for later wiring. |
| External Demon client | Not part of this repository | User-facing docs should not require it for the supported workflow. |

## MVP Roadmap

### Phase 1: Core safety and measurement baseline

| Task | Status | Notes |
|------|--------|-------|
| Core storage tests | Active | Run with `zig build test`. |
| WAL/recovery hardening | Active | Covered by current Kanban slices. |
| Native benchmark runner | Active | Supports cheap memory and persisted smoke runs. |
| Benchmark output/reporting | Active | Tracked by benchmark-specific slices. |

### Phase 2: Protocol and server MVP

| Task | Status | Notes |
|------|--------|-------|
| Align command parser errors | In progress | Missing args and malformed input should return deterministic parser/server errors. |
| Keep KEYS behavior truthful | In progress | Docs must describe regex-style patterns and `*` behavior accurately. |
| Document BENCHMARK split | In progress | Protocol benchmark remains separate from native benchmark until deliberately unified. |
| Wire server into build graph | TODO | Needs a dedicated server/build slice; do not claim `zig build run` support until present. |
| Add deterministic server smoke | TODO | Should happen once server build support is restored. |

### Phase 3: Production readiness

| Task | Status | Notes |
|------|--------|-------|
| Multi-client behavior | TODO | Live ZeroMQ runtime verification is still blocked until the server is restored to the build graph. |
| Graceful shutdown | Source-present / unit-tested helper | `src/server/runtime.zig` covers SIGINT/SIGTERM shutdown state and `src/zserver.zig` checks it, but live server smoke remains blocked by missing build graph support. |
| Structured logging/metrics | In progress / tested core counters | Core storage exposes `store.metrics.snapshot()` for read/write/delete counts, error counts, and total latencies; server source logs lifecycle and shutdown metric snapshots. |
| Sustained smoke/leak checks | Documented core smoke | Use `zig build test` plus `zig build -Doptimize=ReleaseFast benchmark -- 5000 --mode memory --value-size 16 --batch-size 64` for the supported no-artifact smoke path. |

## Verification commands

Minimum local correctness check:

```sh
git status --short --untracked-files=all
zig fmt src build.zig
zig build test
```

Cheap benchmark smoke examples:

```sh
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16
zig build -Doptimize=ReleaseFast benchmark -- 1000 --value-size 16 --batch-size 16 --db-path /tmp/phage-mvp-roadmap-bench
```

Server status check:

```sh
zig build --help
# No default run/server step is currently listed.
```

## Documentation rules for MVP claims

- Do not claim a supported server launch command until the build graph exposes one.
- Do not require the external Demon client for repository-local workflows.
- Describe `KEYS` as regex-style matching with special `*` all-key behavior.
- Describe protocol `BENCHMARK` as separate from the native benchmark runner and mutating the active store.
- Keep generated database, WAL, benchmark-store, and log artifacts out of commits.

## Related documents

- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
