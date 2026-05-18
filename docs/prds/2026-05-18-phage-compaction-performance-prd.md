# PRD: Phage Compaction Performance and Safety

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Make Phage's main-file compaction path measurable, safer to evolve, and faster under update-heavy persisted workloads without weakening recovery guarantees or overstating platform-specific performance.

## Background

The WAL write-path optimization PRD closed the previous highest-leverage storage loop:

- Current HEAD at PRD planning time: `bbab205 docs: refresh Linux io_uring platform note`.
- Recent code commits include `ddc8c91 test(io): cover WAL clear recovery invariants` and `2be5330 perf(io): reduce WAL clear overhead`.
- The curated WAL write-path evidence reports macOS POSIX-fallback write-throughput gains of roughly 14-15% across persisted batch sizes `1`, `16`, and `64` for value size `16` using `getInto`.
- Linux status is no longer deferred: OrbStack NixOS passed Linux `zig build test` after `bc23f18`, and the WAL write-path S4 run recorded `metadata.backend_status=linux-io-uring-intended` for both quick and `linux-io-uring --ops 1000` matrix summaries.
- Gate 2 withholding was remediated by `bbab205`, which refreshed the stale `docs/GETTING_STARTED.md` Linux platform note.

The next strongest storage risk is compaction. The original overnight PRD included S6 "Compaction correctness and performance" and current tests cover repeated updates, index offset preservation, and WAL replay across compaction boundaries. However, current source inspection shows gaps that are now worth isolating:

- `src/root.zig` calls `checkAndScheduleCompaction()` after `put` and `putBatch`; despite comments saying the path is non-blocking/background, `performCompaction()` currently runs inline once the threshold is met.
- `performCompaction()` rewrites reachable entries to `<store>.compact.tmp`, updates index offsets, swaps files with `rename`, and resets `file_size`; this is correctness-sensitive and should not be casually rewritten.
- The existing benchmark matrix measures memory/persisted get/put workloads but does not explicitly create update-heavy waste, force compaction, or report compaction-trigger cost.
- Linux `io_uring` is verified for WAL write-path correctness and cheap persisted rows, but no compaction-focused Linux evidence exists yet.

This PRD chooses compaction performance and safety over deeper WAL tuning, read-path/server throughput, or more Linux infrastructure because the WAL path now has both before/after evidence and Linux status, while compaction remains a correctness-sensitive synchronous rewrite path with limited performance observability.

## Primary goal

Add a compaction-focused measurement path, use it to establish macOS and Linux evidence, and make one small correctness-preserving compaction improvement if the baseline identifies a safe optimization. Accepted work must separate measurement from behavior changes, preserve existing recovery tests, and document before/after evidence without committing generated artifacts.

## Non-goals

- Do not replace the storage format, index implementation, WAL record format, protocol, server concurrency model, or benchmark matrix wholesale.
- Do not remove `fsync`, `rename`, temp-file, WAL clear, or recovery behavior unless a focused test and reviewer-approved evidence prove the replacement is equivalent or safer.
- Do not claim background/non-blocking compaction unless the implementation actually performs compaction off the caller's critical path and the claim is tested or documented as future work.
- Do not claim Linux `io_uring` performance from macOS POSIX-fallback rows.
- Do not change local user, Hermes, Zig, package-manager, OrbStack, or machine configuration.
- Do not commit raw JSONL, summary JSON, database files, WAL files, `.compact.tmp` files, logs, or machine-specific artifacts.
- Do not collapse benchmark support, storage behavior changes, documentation, and Linux verification into one commit.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only and preserve unrelated/untracked files, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, `docs/prds/_template.md`, and generated-looking `matrix.json-summary.json`.
- Prefer TDD for compaction behavior changes and deterministic parser/JSON checks for benchmark-output changes.
- Run `zig fmt src build.zig` for touched Zig files where appropriate.
- Run `zig build test` before implementation slices are considered complete.
- Keep persisted benchmark paths under `/tmp/...`; verify database, WAL, and `.compact.tmp` cleanup after compaction benchmark runs.
- Keep benchmark evidence human-readable in docs or Kanban handoffs; leave raw run artifacts out of git unless a later ticket explicitly approves a small curated summary.
- If Linux is unavailable, block or defer the Linux verification slice with the exact host/tool error instead of fabricating numbers.

## Required gates

This PRD follows the Gate 1 / Gate 2 / Gate 3 loop pattern used by the prior Phage PRDs.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, current git state, compaction source/tests, WAL write-path evidence, Linux verification status, and repository guidance.
3. Create implementation cards for accepted work slices below.
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
2. Inspect git history, working tree, compaction source/tests, benchmark evidence, docs, Linux status, and generated artifact hygiene.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence or explicit deferred/blocker status.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- `zig build test` result is recorded.
- Compaction correctness/recovery evidence is recorded for any changed compaction behavior.
- Before/after or baseline-only compaction benchmark evidence is recorded, with macOS fallback and Linux `io_uring` status separated.
- Working tree status is recorded, with unrelated/untracked files called out.
- No generated benchmark/database/WAL/`.compact.tmp`/log artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, compaction benchmark results, Linux verification status, remediation status, and remaining risks to write the next PRD under `docs/prds/`.
2. Decide whether the next highest-leverage workstream is deeper compaction optimization, read-path/server throughput, Linux verification infrastructure, or another storage correctness gap.
3. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
4. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
5. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Add a compaction-focused benchmark/profile path

Objective: Make compaction cost visible without changing storage semantics.

Candidate tasks:

- Add a focused native benchmark mode, benchmark argument, or matrix profile that creates repeated updates/deletes, forces or naturally triggers compaction, and reports compaction-relevant metrics such as input records, live keys, waste ratio before/after, elapsed compaction cost, file-size reduction, and ordinary write/read latency around the trigger.
- Prefer extending the existing benchmark runner and matrix workflow instead of adding an unrelated script.
- Keep output JSON-compatible where automation already expects JSON; validate with `python3 -m json.tool` or equivalent checks.
- Ensure persisted test paths live under `/tmp/...` and clean the database, `.wal`, and `.compact.tmp` outputs after runs.

Likely files:

- `src/benchmark.zig`
- `bench/benchmark-matrix.sh`
- `bench/benchmark_matrix.py`
- optional tests in existing benchmark/test modules
- optional docs under `docs/benchmarks/`

Acceptance criteria:

- A cheap local compaction benchmark smoke can be run from the repository and produces human-readable and/or JSON evidence naming operation count, live-key count, value size, update rounds, waste ratio before/after, compaction trigger status, backend status, and latency/throughput fields that are meaningful for review.
- Existing benchmark quick profile still works.
- `zig build test` passes.
- Persisted compaction benchmark artifacts are cleaned or explicitly shown to be under `/tmp` and unstaged.
- No storage behavior change is bundled into this slice unless it is strictly instrumentation needed for measurement.

Expected commits:

- `test(benchmark): cover compaction profile output` if tests/checks are added first.
- `feat(benchmark): add compaction workload profile`

### S2: Optimize or clarify compaction execution based on S1 evidence

Objective: Use S1 evidence to make one small compaction-path improvement or, if no safe optimization is evident, correct misleading comments/docs so behavior claims match reality.

Candidate tasks:

- Write focused tests before behavior changes for whichever invariant the change touches: latest-value preservation, index offsets after compaction, delete/recovery across compaction boundary, temp-file cleanup, waste-ratio threshold behavior, or caller-visible synchronous cost.
- Investigate safe improvements such as avoiding per-entry allocation churn during compaction, batching copy buffers, reducing redundant file-stat/ratio work, tightening temp-file cleanup on errors, or correcting the inline-vs-background scheduling claim.
- Preserve the atomic temp-file swap contract and recovery behavior unless the ticket proves a safer equivalent.
- Keep the change intentionally small; create a follow-up card rather than expanding into true asynchronous/background compaction if that requires larger coordination.

Likely files:

- `src/root.zig`
- `src/test_wal_compaction_correctness.zig`
- `src/io/wal.zig` only if WAL-boundary behavior is directly involved
- optional `docs/MVP_ROADMAP.md` or `docs/benchmarks/...` for behavior notes

Acceptance criteria:

- New or updated tests cover the behavior/invariant changed by the slice.
- `zig fmt src build.zig` is run for touched Zig files.
- `zig build test` passes on macOS POSIX fallback.
- A post-change compaction benchmark smoke is recorded and compared to the S1 baseline where comparable.
- The implementation does not delete existing compaction correctness or WAL/recovery coverage.
- No generated `.db`, `.wal`, `.compact.tmp`, JSONL, summary JSON, or log artifacts are staged.

Expected commits:

- `test(io): cover compaction optimization invariants`
- `perf(io): reduce compaction rewrite overhead` or `docs(io): clarify compaction scheduling semantics` depending on the chosen safe change

### S3: Document compaction benchmark evidence and user-facing status

Objective: Make the compaction work auditable without committing raw benchmark artifacts or overstating platform claims.

Candidate tasks:

- Add a curated benchmark/status note under `docs/benchmarks/` for S1/S2 compaction evidence.
- Update `docs/MVP_ROADMAP.md` or another existing status document only if the implementation changed compaction behavior or exposed a new supported benchmark workflow.
- Record exact commands, git revisions, Zig version, platform/backend status, operation counts, compaction trigger fields, before/after numbers, and cleanup/artifact hygiene.
- Keep macOS POSIX-fallback evidence distinct from Linux `io_uring` evidence.

Likely files:

- `docs/benchmarks/2026-05-18-compaction-performance.md`
- `docs/MVP_ROADMAP.md`
- optional `docs/GETTING_STARTED.md` if a supported command deserves user-facing mention

Acceptance criteria:

- Documentation names source commits and exact reproduction commands.
- Documentation includes at least one local macOS POSIX-fallback compaction row or explicitly explains why only baseline instrumentation was accepted.
- Documentation does not commit raw JSONL, summary JSON, database, WAL, `.compact.tmp`, or log artifacts.
- Markdown links are relative and resolve within the docs tree.
- `git diff --check` passes for touched docs.

Expected commits:

- `docs(benchmark): record compaction performance evidence`
- optional `docs: update compaction status notes`

### S4: Verify compaction path on Linux `io_uring`

Objective: Ensure the compaction benchmark and any compaction behavior changes remain correct on the intended Linux backend.

Candidate tasks:

- Run Linux `zig build test` from an approved Linux host/VM/clone with Zig 0.15.x.
- Run the S1 compaction benchmark smoke or matrix profile on Linux with `/tmp/...` persisted paths.
- Validate JSON summaries if produced and record `metadata.backend_status=linux-io-uring-intended`.
- Record exact host, git revision, commands, row counts, representative compaction evidence, cleanup status, and blockers if Linux is unavailable.

Likely files:

- `docs/benchmarks/2026-05-18-compaction-performance.md`
- `docs/benchmarks/2026-05-18-linux-io-uring-verification.md` only if appending Linux status is clearer than a new compaction note
- no source files unless Linux-only defects are discovered and a remediation card is created

Acceptance criteria:

- Linux `zig build test` is either passed on `io_uring` or explicitly blocked with exact host/tool failure.
- Linux compaction benchmark/profile evidence is either recorded with `metadata.backend_status=linux-io-uring-intended` or explicitly deferred by a remediation/blocker card.
- macOS and Linux rows are not conflated.
- No generated Linux or local artifacts are staged.

Expected commits:

- `docs(benchmark): record Linux compaction verification`
- If a Linux-only defect is found, create a remediation card instead of folding the fix into this verification slice.

## Verification commands

Baseline repository checks:

```sh
git status --short --untracked-files=all
zig fmt src build.zig
zig build test
```

Benchmark and evidence checks:

```sh
# Existing quick matrix must keep working.
bench/benchmark-matrix.sh --quick --output /tmp/phage-compaction-prd-quick.jsonl
python3 -m json.tool /tmp/phage-compaction-prd-quick-summary.json >/dev/null

# Exact compaction-profile command will be defined by S1, but it must use /tmp paths
# and leave generated database/WAL/.compact.tmp artifacts out of git.
```

Linux verification, when available:

```sh
git status --short --untracked-files=all
uname -a
zig version
zig build test
# Run the S1 compaction benchmark/profile on Linux and validate any JSON summary.
```

## Completion criteria

- Gate 1 decomposed this PRD into valid Kanban tickets.
- S1 produces a supported compaction-focused benchmark/profile or a reviewed minimal equivalent.
- S2 either ships one small evidence-backed compaction improvement or explicitly documents that no safe optimization was accepted in this loop.
- S3 records curated compaction evidence and status without generated artifacts.
- S4 records Linux `io_uring` compaction status or creates/links a precise blocker/remediation card.
- Gate 2 produces an evidence-based final gap check.
- Gate 3 generates the next PRD and queues the next available work.

## Related documents

- [WAL write-path optimization PRD](2026-05-18-phage-wal-write-path-optimization-prd.md)
- [Benchmark matrix and Linux io_uring verification PRD](2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
- [Overnight Phage work PRD](2026-05-18-overnight-phage-work-prd.md)
- [WAL write-path optimization evidence](../benchmarks/2026-05-18-wal-write-path-optimization.md)
- [Linux io_uring benchmark verification](../benchmarks/2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
