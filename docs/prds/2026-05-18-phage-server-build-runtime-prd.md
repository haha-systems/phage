# PRD: Phage Server Build and Runtime Verification

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Restore the ZeroMQ server from source-present/documented status to a buildable, runnable, and smoke-tested Phage runtime surface, while keeping the core storage and benchmark paths stable.

## Background

The previous Phage overnight PRD completed the core storage, WAL/recovery, benchmark, protocol command, metrics, and documentation-alignment slices. Gate 2 approved the accepted requirements and recorded the remaining deferred/high-leverage items:

- Server build graph/live ZeroMQ smoke.
- Linux-host `io_uring` final performance verification.
- Optional benchmark matrix runner.
- Optional WAL truncation optimization.
- Optional compaction performance optimization.

Current repo inspection shows that `src/zserver.zig` contains a ZeroMQ REP server with command-line parsing, lifecycle logging, SIGINT/SIGTERM shutdown-state checks, and command execution through the protocol layer. However, `build.zig` only exposes `install`, `uninstall`, `benchmark`, and `test`; there is no supported server build/run step. `build.zig.zon` currently has no external dependencies while `src/zserver.zig` imports `zimq`, so server restoration needs an explicit dependency/build strategy rather than a blind build-graph edit.

The next highest-leverage workstream is therefore to make the documented server surface executable and verifiable. Linux-only performance work should wait until the network server has a reproducible build/run/smoke path, because otherwise runtime claims and client behavior remain speculative.

## Primary goal

Expose a supported Phage server build/run workflow and prove it with deterministic live ZeroMQ smoke coverage for the MVP commands: `PING`, `SET`, `GET`, `DELETE`/`DEL`, `KEYS`, and representative malformed/error cases.

## Non-goals

- Do not rewrite the storage engine or protocol command model.
- Do not change local user, Hermes, or global toolchain configuration.
- Do not vendor or pin a new dependency without documenting why that strategy is the smallest stable way to restore server builds.
- Do not claim Linux `io_uring` performance numbers from macOS POSIX fallback smokes.
- Do not commit generated database files, WAL outputs, benchmark stores, logs, or machine-specific artifacts.
- Do not require the external Demon client for repository-local verification.
- Do not collapse build, live-smoke, multi-client, docs, and performance work into one large commit.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only; preserve unrelated/untracked files currently present in the repo, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, and `docs/prds/_template.md` unless a ticket explicitly chooses to stage them.
- Prefer TDD/unit coverage for extracted server config/build helpers and deterministic smoke scripts for live runtime behavior.
- Run `zig fmt src build.zig` for touched Zig files where appropriate.
- Run `zig build test` before considering implementation slices complete.
- For live server smoke checks, use disposable `/tmp/...` database paths and clean them up.
- Preserve macOS POSIX fallback functionality while keeping Linux `io_uring` as the intended high-performance target.
- If `mise trust` blocks verification in `/Users/xiy/code/phage`, agents are allowed to run `mise trust` in this repo per operator note.

## Required gates

This PRD follows the same Gate 1 / Gate 2 / Gate 3 loop pattern as `docs/prds/2026-05-18-overnight-phage-work-prd.md`.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, `AGENTS.md`, current git state, and current server/build files.
3. Create implementation cards for server build restoration, live command smoke, multi-client/sustained runtime checks, and documentation alignment.
4. Create review cards for every implementation card and use parent dependencies so reviews cannot run before implementation completes.
5. Create a Gate 2 final gap-audit card that depends on all review cards.
6. Create a Gate 3 continuation-planning card that depends on Gate 2.
7. Include autonomy policy, PRD slice IDs, likely files, verification commands, expected commit message, and staging hygiene in every implementation/review ticket.

Gate 1 acceptance criteria:

- Kanban cards exist for all accepted implementation slices below.
- Review cards exist and depend on their implementation cards.
- Gate 2 final gap-audit card exists and depends on all review cards.
- Gate 3 continuation-planning card exists and depends on Gate 2.
- The planner summary names the new PRD path and created card IDs.

### Gate 2: Final gap check against this PRD

Owner: `reviewer`

Required actions:

1. Read this PRD line-by-line.
2. Inspect current git history, working tree, build graph, tests, live smoke output, docs, and benchmark status.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence or explicit deferred status.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- `zig build test` result is recorded.
- Server build/run or explicit deferred/blocker status is recorded.
- Live ZeroMQ smoke result is recorded if the server build is restored.
- Working tree status is recorded, with unrelated/untracked files called out.
- No generated server/database/WAL/log artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, benchmark/smoke results, remediation status, and remaining risks to write the next PRD under `docs/prds/`.
2. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
3. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
4. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Server build graph and dependency restoration

Objective: Make `src/zserver.zig` build through a supported Zig build step without regressing the core library, benchmark runner, or tests.

Candidate tasks:

- Inspect the current `zimq` import/build situation and choose the smallest documented dependency strategy that works with Zig 0.15.2.
- Add a supported server executable/build step, e.g. `phage-server` and a `run-server` step, without removing the existing library, benchmark, or test steps.
- Ensure `zig build --help` advertises the server workflow clearly.
- Keep `zig build test` independent of a live network server.
- Document any dependency pin, local fallback, or reason for deferring a full ZeroMQ dependency restoration.

Likely files:

- `build.zig`
- `build.zig.zon` if an explicit package dependency is required
- `src/zserver.zig`
- `src/server/runtime.zig`
- optional docs under `docs/`

Acceptance criteria:

- `zig build --help` lists the supported server build/run step(s).
- The server executable can be built or a precise blocker/remediation card is created if upstream `zimq` cannot be integrated safely.
- `zig build test` still passes.
- Existing `zig build -Doptimize=ReleaseFast benchmark -- ...` workflow remains available.
- Dependency/config changes are documented in the commit or docs, not hidden as local machine state.

Expected commits:

- `build(server): add phage server build step`
- `docs(server): document server build dependency` if docs are changed separately

### S2: Server CLI/config testability and startup hygiene

Objective: Make server argument parsing and startup behavior testable without needing a live socket, so future runtime changes are safer.

Candidate tasks:

- Extract server config parsing and/or usage formatting into a testable module if needed.
- Add tests for `--help`, `--port`, `--db-path`, `--log-level`, invalid ports, unknown arguments, and missing argument values.
- Keep current documented defaults (`5555`, `phage_store`, `info`) unless a concrete bug requires changing them.
- Ensure startup uses explicit disposable paths in smokes and does not create repo-local stores by default during tests.

Likely files:

- `src/zserver.zig`
- `src/server/config.zig` or similar new module if extraction is chosen
- `src/server/runtime.zig`
- `build.zig`

Acceptance criteria:

- Server CLI/config behavior has unit coverage reachable from `zig build test`.
- `--help` can be run without opening a socket or database.
- Invalid arguments fail clearly and do not create repo-local artifacts.
- `zig build test` passes.

Expected commits:

- `test(server): cover server CLI configuration`
- `refactor(server): extract server configuration parsing` if extraction is needed

### S3: Live ZeroMQ MVP command smoke

Objective: Prove the built server can answer the documented MVP command set over ZeroMQ using a repository-local smoke path.

Candidate tasks:

- Add a deterministic smoke command or test harness that starts the built server on an available local port with a `/tmp/...` database path.
- Send `PING`, `SET`, `GET`, `KEYS *`, `KEYS <regex-prefix>`, `DELETE`/`DEL`, a missing-key request, and at least one malformed command.
- Verify expected response payloads and error prefixes.
- Terminate the server cleanly and verify generated database/WAL/log artifacts are not left in the repo.
- Keep the smoke cheap enough for review/final-audit cards to rerun.

Likely files:

- `build.zig`
- `src/zserver.zig`
- `src/protocol/`
- `src/server/`
- `bench/` or `scripts/` if a smoke helper is added
- docs under `docs/` if command examples change

Acceptance criteria:

- A single documented command runs the live ZeroMQ smoke locally on macOS/Linux when dependencies are present.
- The smoke covers all MVP commands listed in `docs/API_REFERENCE.md`.
- The smoke uses a disposable `/tmp/...` database path and does not stage generated files.
- `zig build test` passes after adding the smoke harness.

Expected commits:

- `test(server): add live ZeroMQ command smoke`

### S4: Multi-client and sustained runtime smoke

Objective: Clarify and verify the server's real runtime behavior under repeated and multi-client access without overstating concurrency guarantees.

Candidate tasks:

- Add a bounded repeated-command smoke that exercises multiple client connections or clearly documents why the current REP loop is single-client/serial.
- Record whether Phage supports concurrent clients, serialized REQ/REP handling, or only one active client at a time.
- Verify clean shutdown after repeated requests and check for obvious leaked repo-local artifacts.
- Capture operation metrics/log output at shutdown when practical.

Likely files:

- `src/zserver.zig`
- `src/server/`
- smoke helper under `bench/`, `scripts/`, or `src/`
- `docs/MVP_ROADMAP.md`
- `docs/GETTING_STARTED.md`
- `docs/API_REFERENCE.md`

Acceptance criteria:

- Runtime docs state the verified client/concurrency model accurately.
- Sustained smoke command is documented and repeatable.
- Shutdown metrics/log behavior is captured or explicitly deferred with a reason.
- `zig build test` passes.

Expected commits:

- `test(server): add sustained runtime smoke`
- `docs(server): document verified runtime model`

### S5: Documentation alignment for supported server workflow

Objective: Update user-facing docs after the build and smoke paths are real, removing stale caveats and preserving accurate limitations.

Candidate tasks:

- Update `README.md`, `docs/GETTING_STARTED.md`, `docs/API_REFERENCE.md`, and `docs/MVP_ROADMAP.md` to describe the supported server build/run/smoke commands.
- Keep limitations explicit: ZeroMQ dependency requirements, macOS POSIX fallback, Linux `io_uring` performance target, protocol `BENCHMARK` vs native benchmark split.
- Remove or qualify outdated claims that `zig build run` is unavailable if a new supported run step exists.
- Avoid reintroducing external Demon client requirements.

Likely files:

- `README.md`
- `docs/GETTING_STARTED.md`
- `docs/API_REFERENCE.md`
- `docs/MVP_ROADMAP.md`

Acceptance criteria:

- Docs match the commands and behavior verified by S1-S4.
- Copy-paste server examples use disposable paths where they may create files.
- Related docs remain linked to each other.
- No generated artifacts are staged.

Expected commits:

- `docs(server): document supported server workflow`

## Verification commands

Minimum local correctness check for implementation cards:

```sh
git status --short --untracked-files=all
zig fmt src build.zig
zig build test
```

Build graph and server workflow checks once S1 is implemented:

```sh
zig build --help
zig build phage-server
zig build run-server -- --help
```

Live smoke checks once S3/S4 are implemented; exact command may be defined by implementation, but it must be documented and should use `/tmp/...` paths:

```sh
zig build server-smoke -- --db-path /tmp/phage-server-smoke
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100
```

Benchmark regression smoke for preserving the prior supported workflow:

```sh
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --db-path /tmp/phage-server-prd-bench --json
```

## Completion criteria

This PRD is complete when:

- Gate 1 decomposed this PRD into valid Kanban tickets.
- Accepted implementation slices are completed or explicitly deferred with evidence and remediation cards.
- Review cards approved implementation or created remediation cards.
- Gate 2 produced an evidence-based final gap check.
- Gate 3 generated the next PRD and queued the next available work.

## Related documents

- [Overnight Phage Work PRD](2026-05-18-overnight-phage-work-prd.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [Getting Started](../GETTING_STARTED.md)
- [API Reference](../API_REFERENCE.md)
