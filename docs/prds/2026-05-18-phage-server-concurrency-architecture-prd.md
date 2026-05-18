# PRD: Phage Server Concurrency Architecture

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Turn the newly measured serialized ZeroMQ server runtime into an explicit concurrency architecture decision and, if the audited storage/server boundaries support it, add one bounded opt-in concurrent server mode with conservative benchmark evidence.

## Background

The server throughput and observability PRD closed the previous measurement gap:

- Gate 2 for `docs/prds/2026-05-18-phage-server-throughput-observability-prd.md` approved all accepted slices without remediation.
- Recent commits through `c470d4f docs(server): clarify throughput evidence scope` added and documented `server-load`, curated macOS and Linux throughput rows, and clarified that the current server remains a serialized ZeroMQ REP loop.
- The curated throughput note reports a macOS POSIX-fallback baseline at commit `437eb82`: 1 client / 100 requests at 2,567.53 requests/sec and 215 / 944 / 1,538 us p50/p95/p99 latency, plus 2 clients / 200 total requests at 5,957.35 requests/sec and 194 / 860 / 1,065 us latency.
- The same note reports an OrbStack Linux row at commit `833216f`: 2 clients / 200 total requests at 12,083.50 requests/sec and 124.33 / 281.71 / 457.29 us latency with `backend_status=linux-io-uring-intended`.
- All server-load evidence is labeled `runtime_model=multi-client-serialized-req-rep`, which verifies bounded multi-client request/reply behavior but not parallel command execution.
- `src/zserver.zig` currently owns one `phage.Phage` store and one ZeroMQ REP socket, receives one message, executes one parsed command, sends one reply, and repeats.
- Core storage now has explicit mutation serialization and public-read/compaction generation locks in `src/root.zig`; metrics counters are atomic. However, server-level concurrency has not been audited end-to-end across store operations, protocol payload ownership, ZeroMQ socket ownership, shutdown handling, and benchmark/reporting semantics.

The next highest-leverage workstream is server concurrency architecture rather than another local response-path micro-optimization or protocol ergonomics slice. The project now has enough load evidence to justify answering whether Phage can safely expose a bounded concurrent server mode, and doing that safely requires an architecture gate before implementation.

## Primary goal

Produce a reviewed server concurrency design for Phage and, only if the design audit finds the storage/protocol/runtime boundaries safe enough, implement one bounded opt-in concurrent server runtime path that preserves the existing default serialized REP workflow, protocol responses, artifact hygiene, and macOS-vs-Linux evidence separation.

## Non-goals

- Do not replace ZeroMQ with another transport in this PRD.
- Do not remove or change the default serialized REP server workflow unless a failing test proves it is already broken.
- Do not claim parallel store writes or linear throughput scaling unless the implementation and benchmark evidence actually demonstrate it.
- Do not change the on-wire text protocol, add quoted/multi-word values, or alter command response strings except where a focused test covers a bug fix required by the concurrency work.
- Do not rewrite the storage format, WAL format, index implementation, compaction policy, or native benchmark matrix wholesale.
- Do not add unbounded worker/thread counts, unbounded request queues, or benchmarks that run indefinitely.
- Do not change local user, Hermes, Zig, package-manager, OrbStack, ZeroMQ, or machine configuration.
- Do not commit raw JSONL, summary JSON, database files, WAL files, `.compact.tmp` files, server logs, temporary clone directories, or machine-specific artifacts.
- Do not collapse architecture audit, handler refactor, concurrent runtime, benchmark evidence, docs, reviews, and final audit into one commit.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only and preserve unrelated/untracked files, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, `docs/prds/_template.md`, and generated-looking `matrix.json-summary.json`.
- Prefer TDD/unit tests for config parsing, command-handler behavior, worker-count bounds, runtime-model reporting, and any changed shutdown/error behavior.
- Run `zig fmt src build.zig` for touched Zig files where appropriate.
- Run `zig build test` before implementation slices are considered complete.
- Keep the existing smoke/load commands working: `server-smoke`, `server-sustained-smoke`, and `server-load`.
- Use disposable `/tmp/...` server database paths for live smokes and load runs; verify database, WAL, and `.compact.tmp` cleanup after runs.
- Keep benchmark/load evidence human-readable in docs or Kanban handoffs; leave raw run artifacts out of git unless a later ticket explicitly approves a small curated summary.
- If Linux, ZeroMQ/libzmq, or a safe concurrent store boundary is unavailable, block or defer with the exact host/tool/source-level reason instead of fabricating a concurrent result.
- If the S1 architecture audit rejects a concurrent runtime for now, subsequent implementation work should pivot to documenting blockers and creating focused follow-up cards rather than forcing a risky prototype.

## Required gates

This PRD follows the Gate 1 / Gate 2 / Gate 3 loop pattern used by the prior Phage PRDs.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, current git state, server source/smokes/load harness, server throughput evidence, Linux status, docs status, and repository guidance.
3. Create implementation cards for the accepted work slices below.
4. Create review cards for implementation cards and use parent dependencies so reviews cannot run before implementation completes.
5. Create a Gate 2 final gap-audit card that depends on all review cards.
6. Create a Gate 3 continuation-planning card that depends on Gate 2.
7. Include autonomy policy, PRD slice IDs, likely files, verification commands, expected commit message, and staging hygiene in every implementation/review ticket.

Gate 1 acceptance criteria:

- Kanban cards exist for all accepted implementation slices below.
- Review cards exist and depend on their implementation cards.
- Gate 2 final gap-audit card exists and depends on all review cards.
- Gate 3 continuation-planning card exists and depends on Gate 2.
- The planner summary names this PRD path and created card IDs.

### Gate 2: Final gap check against this PRD

Owner: `reviewer`

Required actions:

1. Read this PRD line-by-line.
2. Inspect git history, working tree, server source/smokes/load harness, architecture note, benchmark evidence, docs, Linux status, and generated artifact hygiene.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence or explicit deferred/blocker status.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- `zig build test` result is recorded.
- Serialized server smoke/load results are recorded after the work.
- If a concurrent mode is implemented, concurrent-mode smoke/load results are recorded with worker count, request count, request mix, runtime model, backend/platform status, error counts, latency percentiles, shutdown metrics, and cleanup evidence.
- If concurrent mode is deferred, the audit records the exact blocker and validates that default serialized behavior and docs remain truthful.
- macOS POSIX-fallback and Linux `io_uring` evidence are separated.
- Working tree status is recorded, with unrelated/untracked files called out.
- No generated benchmark/database/WAL/`.compact.tmp`/log artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, concurrency/load evidence, Linux verification status, remediation status, and remaining risks to write the next PRD under `docs/prds/`.
2. Decide whether the next highest-leverage workstream is protocol ergonomics, Linux verification infrastructure, storage correctness gaps, compaction hardening leftovers, concurrency follow-up, or another measured bottleneck.
3. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
4. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
5. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Audit and document the server concurrency design

Objective: Decide, with source-level evidence, whether Phage can safely support a bounded concurrent server runtime now and what the minimal safe runtime shape should be.

Candidate tasks:

- Audit `src/zserver.zig`, `src/root.zig`, `src/index.zig`, `src/io/`, `src/metrics/metrics.zig`, and `src/server/` for thread-safety and ownership boundaries relevant to serving multiple requests concurrently.
- Document the current serialized REP runtime and the proposed opt-in concurrency shape, likely a ZeroMQ ROUTER-style frontend or equivalent bounded dispatcher that keeps per-socket ownership thread-local and uses worker count limits.
- Explicitly decide whether worker threads may share one `phage.Phage` instance for reads/writes, whether writes remain serialized by existing store locks, and what risks remain around backend completion queues, compaction, metrics, and shutdown.
- Define acceptance criteria for `--workers`, runtime-model labels, queue bounds, shutdown semantics, and benchmark evidence before implementation starts.
- If the audit finds an unsafe blocker, document it precisely and create a follow-up implementation/remediation path instead of proceeding blindly.

Likely files:

- `docs/design/2026-05-18-server-concurrency-architecture.md` or `docs/benchmarks/2026-05-18-server-concurrency.md`
- `docs/MVP_ROADMAP.md` if a concise status note is useful
- optional focused tests under existing storage/server test files if the audit needs a reproducible safety check

Acceptance criteria:

- A committed design/evidence note names the chosen runtime shape or explains why concurrent runtime implementation is deferred.
- The note cites source-level evidence for store mutation locks, read/compaction locks, metrics atomics, protocol payload ownership, and ZeroMQ socket ownership constraints.
- The note names which parts are safe to proceed with, which remain risky, and what S2/S3 must preserve.
- `git diff --check` passes.
- `zig build test` passes unless the slice is docs-only and the card explicitly records why a docs-only subset was used.
- No generated database, WAL, JSON, log, temporary clone, or machine-specific artifacts are staged.

Expected commits:

- `docs(server): add concurrency architecture audit`
- optional `test(storage): cover concurrent server safety boundary` if a focused source-level check is added

### S2: Extract reusable server command handling while preserving serialized REP behavior

Objective: Separate parse/execute/response formatting from the socket receive/send loop so the default server can be tested and a future concurrent runtime can reuse exactly the same protocol behavior.

Candidate tasks:

- Introduce a small server command handler module that accepts a request slice, executes it against a `phage.Phage` store, and returns or sends the same response bytes as the existing server path.
- Preserve existing parser errors, execution errors, borrowed/static response handling, allocation ownership, and payload cleanup behavior.
- Add focused tests that compare handler responses for `PING`, `SET`, `GET`, `DELETE`/`DEL`, `KEYS`, malformed commands, missing keys/values/patterns, invalid patterns, and `BENCHMARK 1` where practical.
- Refactor `src/zserver.zig` to call the handler without changing the default REP runtime model.
- Keep S2 free of worker pools, ROUTER sockets, batching, protocol changes, or benchmark-claim updates beyond notes needed for the refactor.

Likely files:

- `src/zserver.zig`
- new `src/server/handler.zig` or similar
- `src/server/*.zig` tests or existing protocol/server tests
- `build.zig` only if a new test module must be wired explicitly

Acceptance criteria:

- Focused tests cover the extracted handler's success and error responses.
- Existing server command responses remain byte-for-byte compatible for the MVP command set and documented error cases.
- `zig fmt src build.zig` passes for touched Zig files.
- `zig build test` passes.
- `zig build server-smoke -- --db-path /tmp/phage-server-handler-smoke` passes.
- `zig build server-sustained-smoke -- --db-path /tmp/phage-server-handler-sustained --clients 2 --requests 100` passes.
- A cheap `server-load` run records the same `multi-client-serialized-req-rep` runtime model after refactor.
- No generated database, WAL, JSON, log, or machine-specific artifacts are staged.

Expected commits:

- `test(server): cover command handler responses`
- `refactor(server): extract command handler from REP loop`

### S3: Add a bounded opt-in concurrent server runtime if S1 approves it

Objective: Implement one minimal concurrent server runtime path that is disabled by default, bounded by explicit worker limits, and measured separately from the serialized REP loop.

Candidate tasks:

- Add server configuration for runtime mode and worker count, for example `--runtime serialized|concurrent` and `--workers N`, while preserving the current default serialized mode.
- Reject unsafe worker counts such as zero, negative values, and unreasonably large values; document the chosen cap.
- Implement the audited runtime shape from S1, keeping ZeroMQ socket usage thread-safe and preserving request/reply correlation.
- Ensure shutdown drains or terminates workers predictably and still logs final store metrics.
- If S1 rejects concurrent runtime as unsafe, do not implement this slice; instead complete the card with the exact blocker, docs update, and follow-up cards for the required prerequisite.

Likely files:

- `src/server/config.zig`
- `src/zserver.zig`
- new `src/server/concurrent_runtime.zig` or similar
- `src/server/runtime.zig`
- `src/server/load_smoke.zig`
- `src/server/sustained_smoke.zig`
- `docs/API_REFERENCE.md` and `docs/GETTING_STARTED.md` only if new flags become user-facing in this slice
- `build.zig` only if a new module/test step must be wired

Acceptance criteria:

- Default `zig build run-server -- --help` and default server execution remain serialized unless the caller opts into the concurrent runtime.
- Config tests cover runtime-mode parsing, worker-count bounds, defaults, and help text.
- Focused runtime tests or live smokes cover the concurrent mode's request/reply correctness for the MVP command set.
- `zig fmt src build.zig` passes for touched Zig files.
- `zig build test` passes.
- `zig build server-smoke -- --db-path /tmp/phage-server-concurrency-serialized-smoke` passes in the default serialized mode.
- `zig build server-sustained-smoke -- --db-path /tmp/phage-server-concurrency-sustained --clients 2 --requests 100` passes.
- A concurrent-mode smoke/load command passes if the mode is implemented, records runtime model and worker count, and cleans generated artifacts.
- Protocol response strings remain compatible unless an explicitly tested bug fix is accepted.
- No generated database, WAL, JSON, log, or machine-specific artifacts are staged.

Expected commits:

- `test(server): cover concurrent runtime config`
- `feat(server): add bounded concurrent runtime mode` or `docs(server): defer concurrent runtime on safety blocker`

### S4: Record concurrency evidence and align user-facing docs

Objective: Make concurrency claims truthful by recording before/after load evidence and updating user-facing docs only to the level actually implemented.

Candidate tasks:

- Run the default serialized load command after S2/S3 and compare it to the existing server throughput evidence where comparable.
- If concurrent mode was implemented, run a cheap concurrent-mode load shape on macOS POSIX fallback and, if available, on Linux `io_uring`; record worker count, client count, request count, request mix, runtime model, backend status, throughput, p50/p95/p99 latency, error counts, shutdown metrics, and cleanup evidence.
- If concurrent mode was deferred, document the blocker and keep docs clear that Phage remains serialized.
- Update `docs/GETTING_STARTED.md`, `docs/API_REFERENCE.md`, and `docs/MVP_ROADMAP.md` only where needed to describe the accepted runtime modes and status.
- Keep raw JSON/log artifacts in `/tmp` and commit only curated Markdown evidence.

Likely files:

- `docs/benchmarks/2026-05-18-server-concurrency.md`
- `docs/GETTING_STARTED.md`
- `docs/API_REFERENCE.md`
- `docs/MVP_ROADMAP.md`
- optional links from `docs/benchmarks/2026-05-18-server-throughput.md`

Acceptance criteria:

- Curated docs record exact commands, git revision, Zig version, OS/platform, backend status, runtime model, worker count where applicable, request/client shapes, throughput, latency percentiles, command/error counts, shutdown metrics, and artifact cleanup.
- macOS POSIX-fallback and Linux `io_uring` rows are clearly separated.
- User-facing docs do not claim concurrent execution unless concurrent mode is implemented and smoke/load evidence exists.
- Relative Markdown links in touched docs resolve.
- `git diff --check` passes.
- `zig build test` or a documented docs-only verification subset passes.
- No raw load artifacts, databases, WALs, logs, temporary clone directories, or generated summaries are staged.

Expected commit:

- `docs(server): record concurrency runtime status`

## Verification commands

Minimum local correctness and hygiene checks:

```sh
git status --short --untracked-files=all
git log --oneline -20
git diff --check
zig fmt src build.zig
zig build test
zig build server-smoke -- --db-path /tmp/phage-server-concurrency-smoke
zig build server-sustained-smoke -- --db-path /tmp/phage-server-concurrency-sustained --clients 2 --requests 100
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-server-concurrency-load --clients 2 --requests 100 --json > /tmp/phage-server-concurrency-load.json
python3 -m json.tool /tmp/phage-server-concurrency-load.json >/dev/null
```

If an opt-in concurrent mode is implemented, the implementation must define the final command shape. The expected smoke/load shape should include explicit runtime mode and worker count, for example:

```sh
zig build server-sustained-smoke -- --db-path /tmp/phage-server-concurrency-workers-smoke --clients 4 --requests 100 --runtime concurrent --workers 2
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-server-concurrency-workers-load --clients 4 --requests 100 --runtime concurrent --workers 2 --json > /tmp/phage-server-concurrency-workers-load.json
python3 -m json.tool /tmp/phage-server-concurrency-workers-load.json >/dev/null
```

Linux verification, only on an available Linux host with Zig 0.15.2 and ZeroMQ/libzmq support:

```sh
zig build test
zig build server-smoke -- --db-path /tmp/phage-linux-concurrency-server-smoke
zig build server-sustained-smoke -- --db-path /tmp/phage-linux-concurrency-sustained --clients 2 --requests 100
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-linux-concurrency-load --clients 2 --requests 100 --json > /tmp/phage-linux-concurrency-load.json
python3 -m json.tool /tmp/phage-linux-concurrency-load.json >/dev/null
```

## Completion criteria

- Gate 1 decomposed this PRD into valid Kanban tickets with implementation, review, final-audit, and continuation cards.
- Accepted implementation slices are complete or explicitly deferred with precise blockers/remediation cards.
- Review cards approved implementations or created remediation cards.
- Gate 2 produced an evidence-based final gap check against this PRD.
- Gate 3 generated the next PRD and queued the next available work.

## Related documents

- [Server throughput and observability PRD](2026-05-18-phage-server-throughput-observability-prd.md)
- [Server build and runtime verification PRD](2026-05-18-phage-server-build-runtime-prd.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [API Reference](../API_REFERENCE.md)
- [Getting Started](../GETTING_STARTED.md)
- [Server throughput baseline evidence](../benchmarks/2026-05-18-server-throughput.md)
- [Linux io_uring benchmark verification](../benchmarks/2026-05-18-linux-io-uring-verification.md)
