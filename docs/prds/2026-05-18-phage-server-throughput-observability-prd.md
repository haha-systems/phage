# PRD: Phage Server Throughput and Observability

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Make Phage's ZeroMQ server runtime measurable under bounded multi-client traffic, then use that evidence to make one safe server read/response-path improvement without overstating concurrency or Linux performance claims.

## Background

The compaction performance and safety PRD closed the previous core-storage evidence loop:

- Current HEAD at PRD planning time: `cdd6d2c docs: update Linux compaction status notes`.
- The accepted compaction chain added `--profile compaction`, hardened failed inline compaction cleanup, serialized compaction with mutations and public reads, recorded macOS POSIX-fallback evidence, and verified the compaction profile on Linux `io_uring`.
- Gate 2 for the compaction PRD withheld final approval only for stale user-facing Linux compaction status notes; remediation `t_ec434124` updated `docs/GETTING_STARTED.md` and `docs/MVP_ROADMAP.md` in commit `cdd6d2c`.
- Broader compaction hardening follow-ups already exist outside this PRD: swap reopen semantics (`t_fd0d9c7d`), temp/directory durability (`t_c3c78dce`), and a final hardening audit (`t_a8e94c5e`). This PRD must not duplicate or preempt those cards.

The next highest-leverage workstream is server throughput observability rather than deeper compaction tuning:

- `docs/MVP_ROADMAP.md` and `docs/API_REFERENCE.md` now describe a supported server workflow: `phage-server`, `run-server`, `server-smoke`, and `server-sustained-smoke`.
- A Gate 3 planning smoke on macOS passed: `zig build server-sustained-smoke -- --db-path /tmp/phage-gate3-server-sustained --clients 2 --requests 20` reported `total_requests=40`, `runtime_model=multi-client-serialized-req-rep`, and shutdown counters `reads=10 writes=10 deletes=10 read_errors=0 write_errors=0 delete_errors=0`; generated `/tmp` store/WAL artifacts were absent afterward.
- The server runtime remains intentionally serialized: `src/zserver.zig` uses a single ZeroMQ REP receive/execute/send loop. Current smokes prove bounded command correctness and shutdown metrics, not throughput scaling, latency percentiles, queueing behavior, or server read-path efficiency.
- Native storage benchmarks already show why read-path choices matter: `getInto` avoids caller-visible allocations, while the server command path currently formats protocol responses through allocation-owning result payloads.

This PRD chooses measurement first, then a bounded server read/response-path improvement, because the project now has reliable storage benchmarks and server smoke coverage but lacks comparable network/runtime numbers.

## Primary goal

Add a reproducible server load/throughput measurement path for the current serialized REQ/REP runtime, establish baseline evidence, and make one small correctness-preserving server read/response-path improvement if the baseline identifies a safe optimization. Accepted work must preserve the supported server smoke commands, keep generated artifacts out of git, and separate macOS POSIX-fallback evidence from Linux `io_uring` evidence.

## Non-goals

- Do not replace ZeroMQ, rewrite the protocol, introduce a different network transport, or convert the server to a parallel/asynchronous execution model in this PRD.
- Do not claim parallel command execution or throughput scaling with client count while `src/zserver.zig` remains a single REP loop.
- Do not rewrite the storage format, index implementation, WAL format, compaction policy, or benchmark matrix wholesale.
- Do not duplicate or block the existing compaction hardening follow-ups (`t_fd0d9c7d`, `t_c3c78dce`, `t_a8e94c5e`).
- Do not claim Linux `io_uring` server performance from macOS POSIX-fallback runs.
- Do not change local user, Hermes, Zig, package-manager, OrbStack, ZeroMQ, or machine configuration.
- Do not commit raw JSONL, summary JSON, database files, WAL files, `.compact.tmp` files, server logs, or machine-specific artifacts.
- Do not collapse load-harness, baseline docs, server optimization, Linux verification, and user-facing docs into one commit.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only and preserve unrelated/untracked files, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, `docs/prds/_template.md`, and generated-looking `matrix.json-summary.json`.
- Prefer TDD/unit tests for argument parsing, JSON summary formatting, request-mix generation, and response handling.
- Run `zig fmt src build.zig` for touched Zig files where appropriate.
- Run `zig build test` before implementation slices are considered complete.
- Use disposable `/tmp/...` server database paths for live smokes and load runs; verify database and WAL cleanup after runs.
- Keep benchmark/load evidence human-readable in docs or Kanban handoffs; leave raw run artifacts out of git unless a later ticket explicitly approves a small curated summary.
- If Linux or ZeroMQ/libzmq is unavailable for a Linux verification slice, block or defer with the exact host/tool error instead of fabricating numbers.

## Required gates

This PRD follows the Gate 1 / Gate 2 / Gate 3 loop pattern used by the prior Phage PRDs.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, current git state, server source/smokes, benchmark evidence, Linux status, docs status, and repository guidance.
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
2. Inspect git history, working tree, server source/smokes, load evidence, docs, Linux status, and generated artifact hygiene.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence or explicit deferred/blocker status.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- `zig build test` result is recorded.
- Server smoke and sustained/load results are recorded, including request counts, client counts, runtime model, backend/platform status, and cleanup evidence.
- Any server read/response-path behavior change has focused tests and before/after load evidence where comparable.
- macOS POSIX-fallback and Linux `io_uring` evidence are separated.
- Working tree status is recorded, with unrelated/untracked files called out.
- No generated benchmark/database/WAL/`.compact.tmp`/log artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, server throughput/load evidence, Linux verification status, remediation status, and remaining risks to write the next PRD under `docs/prds/`.
2. Decide whether the next highest-leverage workstream is server concurrency architecture, protocol ergonomics, Linux verification infrastructure, storage correctness gaps, or another measured bottleneck.
3. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
4. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
5. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Add a bounded server load/throughput harness

Objective: Extend the existing repository-local server smoke workflow into a reproducible measurement path without changing server semantics.

Candidate tasks:

- Add a `server-load` or similarly named build step that starts the built `phage-server` on an available localhost port and drives a bounded request mix from one or more REQ clients.
- Reuse the current smoke/sustained-smoke structure where practical; do not duplicate process startup, port selection, `/tmp` database cleanup, or request helpers unnecessarily.
- Emit human-readable output and optional JSON summary with at least: client count, requests per client, total requests, request mix, runtime model, backend/platform status if available, elapsed time, total requests/sec, per-command counts, error counts, and p50/p95/p99 request latency.
- Keep default limits small enough for reviewers; reject unbounded request counts or unsafe database paths.
- Validate JSON output with deterministic tests or smoke checks.

Likely files:

- `build.zig`
- `src/server/sustained_smoke.zig`
- optional new `src/server/load_smoke.zig` or `src/server/load_benchmark.zig`
- optional shared helper under `src/server/`
- `docs/API_REFERENCE.md` or `docs/GETTING_STARTED.md` only if a new supported command is user-facing in this slice

Acceptance criteria:

- A cheap load command can be run from the repository and reports total request count, client count, runtime model, throughput, latency percentiles, command/error counts, and cleanup status.
- Existing `zig build server-smoke` and `zig build server-sustained-smoke` still pass.
- `zig build test` passes.
- The harness refuses unsafe non-`/tmp` generated database paths unless explicitly supplied by the caller.
- No storage/server behavior change is bundled into this slice unless strictly needed for measurement.
- No generated database, WAL, JSON, log, or machine-specific artifacts are staged.

Expected commits:

- `test(server): cover load harness output` if parser/summary tests are added first.
- `feat(server): add bounded load smoke harness`

### S2: Establish curated server load baselines

Objective: Record comparable baseline evidence for the current serialized server runtime before optimizing it.

Candidate tasks:

- Run the S1 load harness on macOS POSIX fallback with at least two small shapes, for example 1 client and 2 or 4 clients, using the same request mix and request count where practical.
- Include `zig version`, git revision, OS/platform, backend/platform status, exact commands, request mix, throughput, latency percentiles, command/error counts, shutdown metrics, and cleanup evidence.
- Keep raw JSON/log artifacts under `/tmp` and out of git; commit only a curated Markdown evidence note.
- Interpret the results conservatively: the server is serialized, so multi-client rows are queueing/REQ/REP evidence rather than proof of parallel command execution.

Likely files:

- `docs/benchmarks/2026-05-18-server-throughput.md`
- optional `docs/MVP_ROADMAP.md` status note if a new supported load command exists
- optional `docs/API_REFERENCE.md` command note if not covered in S1

Acceptance criteria:

- Baseline docs name source commit, commands, host/tool metadata, request/client shapes, throughput, p50/p95/p99 latency, command/error counts, shutdown metrics, and artifact cleanup.
- The docs explicitly label macOS rows as POSIX-fallback/local server evidence, not Linux `io_uring` evidence.
- `zig build test` or a documented docs-only verification subset passes.
- Relative Markdown links in touched docs resolve.
- No raw load artifacts, databases, WALs, logs, or generated summaries are staged.

Expected commit:

- `docs(benchmark): record server throughput baseline`

### S3: Optimize one server read/response-path bottleneck

Objective: Use S2 evidence and source inspection to make one small server-path improvement while preserving the text protocol and serialized runtime model.

Candidate tasks:

- Prefer improvements with focused tests and limited blast radius, such as avoiding avoidable allocation in GET response handling, reusing bounded buffers in load/smoke clients, tightening response formatting, or reducing debug output in hot request paths if it measurably affects load rows.
- If no safe optimization is evident, correct misleading docs/comments and create a follow-up rather than forcing a risky change.
- Do not introduce parallel command execution, a worker pool, new protocol framing, or server-side batching in this PRD.
- Preserve existing protocol responses for `PING`, `SET`, `GET`, `DELETE`/`DEL`, `KEYS`, and malformed input.

Likely files:

- `src/zserver.zig`
- `src/protocol/commands.zig`
- `src/protocol/command_execution_test.zig`
- `src/server/smoke.zig`
- `src/server/sustained_smoke.zig`
- optional new or existing server load harness file from S1

Acceptance criteria:

- Focused tests cover any changed response behavior or helper semantics before/with the implementation.
- `zig fmt src build.zig`, `zig build test`, `zig build server-smoke`, and `zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-prd --clients 2 --requests 100` pass.
- A post-change load run is recorded and compared to the S2 baseline where comparable.
- The server remains a serialized REP loop unless a future PRD accepts a concurrency architecture change.
- No generated database, WAL, load output, logs, or machine-specific artifacts are staged.

Expected commits:

- `test(server): cover response path optimization`
- `perf(server): reduce response-path overhead` or `docs(server): clarify serialized throughput limits` depending on the chosen safe change

### S4: Verify Linux/server-platform status for the load path

Objective: Keep Linux `io_uring` and macOS POSIX-fallback server evidence separate while checking whether the load path runs on the intended Linux backend.

Candidate tasks:

- If a Linux host is available, run `zig build test`, the server smoke, sustained smoke, and a cheap S1/S3 load harness command from a temporary Linux clone or clean working tree.
- Record whether `zimq`/libzmq and Zig 0.15.2 are available without changing machine configuration.
- Record exact Linux commands, host metadata, backend/platform status, request shape, throughput/latency, shutdown metrics, and cleanup evidence.
- If Linux is unavailable or the server dependency cannot run there, block/defer with the exact host/tool error and avoid claiming Linux server performance.

Likely files:

- `docs/benchmarks/2026-05-18-server-throughput.md`
- optional `docs/benchmarks/2026-05-18-linux-io-uring-verification.md` cross-reference
- optional `docs/MVP_ROADMAP.md` status note

Acceptance criteria:

- Linux result is either real evidence with `backend_status=linux-io-uring-intended` or an explicit blocker/deferred status with exact error output.
- Linux and macOS evidence are clearly separated in docs and handoffs.
- Raw Linux JSON/log/database/WAL artifacts are removed or left under `/tmp` and unstaged.
- Relative Markdown links in touched docs resolve.

Expected commit:

- `docs(benchmark): record Linux server throughput status`

### S5: Align user-facing server performance docs

Objective: Keep supported workflows truthful after the load harness, baseline, and any read/response optimization land.

Candidate tasks:

- Update `docs/GETTING_STARTED.md`, `docs/API_REFERENCE.md`, and `docs/MVP_ROADMAP.md` only where needed to describe the supported load command, current server throughput status, and serialized runtime limits.
- Link to the curated server throughput evidence note rather than committing raw artifacts.
- Preserve existing guidance that native storage benchmarks are separate from protocol `BENCHMARK` and live server load checks.
- Avoid implying Linux performance if only macOS fallback evidence exists.

Likely files:

- `docs/GETTING_STARTED.md`
- `docs/API_REFERENCE.md`
- `docs/MVP_ROADMAP.md`
- `docs/benchmarks/2026-05-18-server-throughput.md`

Acceptance criteria:

- User-facing docs list the new load command only if S1 accepted it as supported.
- Docs accurately state the verified runtime model and any accepted optimization without claiming parallelism.
- Relative Markdown links in touched docs resolve.
- `git diff --check` passes.
- No generated artifacts are staged.

Expected commit:

- `docs(server): document throughput workflow status`

## Verification commands

Minimum local correctness and hygiene checks:

```sh
git status --short --untracked-files=all
git log --oneline -20
git diff --check
zig fmt src build.zig
zig build test
zig build server-smoke -- --db-path /tmp/phage-server-smoke-prd
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-prd --clients 2 --requests 100
```

S1/S3 load evidence command shape, to be finalized by the implementation:

```sh
zig build server-load -- --db-path /tmp/phage-server-load-prd --clients 2 --requests 100 --json > /tmp/phage-server-load-prd.json
python3 -m json.tool /tmp/phage-server-load-prd.json >/dev/null
```

Linux verification, only on an available Linux host with Zig 0.15.2 and ZeroMQ/libzmq support:

```sh
zig build test
zig build server-smoke -- --db-path /tmp/phage-linux-server-smoke
zig build server-sustained-smoke -- --db-path /tmp/phage-linux-server-sustained --clients 2 --requests 100
zig build server-load -- --db-path /tmp/phage-linux-server-load --clients 2 --requests 100 --json > /tmp/phage-linux-server-load.json
python3 -m json.tool /tmp/phage-linux-server-load.json >/dev/null
```

## Completion criteria

- Gate 1 decomposed this PRD into valid Kanban tickets with implementation, review, final-audit, and continuation cards.
- Accepted implementation slices are complete or explicitly deferred with precise blockers/remediation cards.
- Review cards approved implementations or created remediation cards.
- Gate 2 produced an evidence-based final gap check against this PRD.
- Gate 3 generated the next PRD and queued the next available work.

## Related documents

- [Compaction performance and safety PRD](2026-05-18-phage-compaction-performance-prd.md)
- [Server build and runtime verification PRD](2026-05-18-phage-server-build-runtime-prd.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [API Reference](../API_REFERENCE.md)
- [Getting Started](../GETTING_STARTED.md)
- [Compaction benchmark and status evidence](../benchmarks/2026-05-18-compaction-performance.md)
- [Linux io_uring benchmark verification](../benchmarks/2026-05-18-linux-io-uring-verification.md)
