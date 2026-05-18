# PRD: Phage Benchmark Matrix and Linux io_uring Verification

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Turn Phage's ad hoc benchmark smokes into a reproducible benchmark matrix and use it to separate macOS POSIX-fallback measurements from final Linux `io_uring` performance evidence before starting the next storage optimization tranche.

## Background

The server build/runtime PRD completed the supported ZeroMQ server workflow: `phage-server`, `run-server`, `server-smoke`, and `server-sustained-smoke` are now buildable and smoke-tested. Gate 2 for that PRD approved all accepted server requirements and recorded these verification highlights:

- `zig build test` passed across benchmark, root/lib, protocol command, server config/runtime, compaction, and replay coverage.
- `zig build phage-server`, `zig build run-server -- --help`, `zig build server-smoke`, and `zig build server-sustained-smoke` passed.
- A cheap memory-mode JSON benchmark smoke passed with `write_ops_per_sec=8474576.27`, `read_ops_per_sec=24390243.90`, `total_ops_per_sec=12578616.35`, write `p95=0.31us`, and read `p99=1.00us`.
- The final server audit left the working tree with only known unrelated/untracked files: `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, and `docs/prds/_template.md`.

Fresh PRD-planning inspection on 2026-05-18 found the same clean tracked state plus the known untracked files. It also ran quick local benchmark JSON checks with `--read-api get-into`:

- Memory mode, 1,000 ops, value size 16, batch size 16: write throughput `4016064.26 ops/sec`, read throughput `18181818.18 ops/sec`, total throughput `6578947.37 ops/sec`, write p95 `0.44us`, read p99 `1.00us`.
- Persisted mode on macOS POSIX fallback, 1,000 ops, value size 16, batch size 16: write throughput `1259445.84 ops/sec`, read throughput `1173708.92 ops/sec`, total throughput `1215066.83 ops/sec`, write p95 `1.06us`, read p99 `1.00us`.

The evidence points to benchmark reproducibility and Linux-backend verification as the next highest-leverage workstream. WAL truncation and compaction performance optimization remain plausible follow-ups, but they should be prioritized from a repeatable matrix rather than one-off local smokes.

## Primary goal

Add a repository-local benchmark matrix workflow that emits machine-readable, artifact-safe results for common Phage workloads, then use it to capture macOS fallback baselines and either record Linux `io_uring` evidence or create a precise blocker/follow-up for missing Linux execution capacity.

## Non-goals

- Do not optimize WAL truncation, compaction, index layout, or server concurrency in this PRD unless a ticket explicitly creates a tiny instrumentation-only helper required by the matrix.
- Do not claim Linux `io_uring` performance from macOS POSIX fallback results.
- Do not change local user, Hermes, Zig, package-manager, or machine configuration.
- Do not commit generated database files, WAL outputs, benchmark stores, logs, or large benchmark result artifacts.
- Do not replace the existing single-run `zig build -Doptimize=ReleaseFast benchmark -- ...` workflow.
- Do not require the ZeroMQ server or external Demon client for native storage benchmark matrix runs.
- Do not collapse runner implementation, docs, Linux execution, and final audit into one large commit.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only; preserve unrelated/untracked files currently present in the repo, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, and `docs/prds/_template.md` unless a ticket explicitly chooses to stage them.
- Prefer deterministic tests for benchmark argument parsing, result parsing, and matrix aggregation; use smoke commands for measured output.
- Run `zig fmt src build.zig` for touched Zig files where appropriate.
- Run `zig build test` before considering implementation slices complete.
- Use disposable `/tmp/...` paths for persisted benchmark runs and clean up `.wal` files.
- Preserve macOS POSIX fallback functionality while keeping Linux `io_uring` as the intended high-performance target.
- If a task needs a Linux host and none is available, block with a precise reason or create a follow-up Linux-execution card rather than inventing numbers.

## Required gates

This PRD follows the Gate 1 / Gate 2 / Gate 3 loop pattern used by `docs/prds/2026-05-18-overnight-phage-work-prd.md` and `docs/prds/2026-05-18-phage-server-build-runtime-prd.md`.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, `AGENTS.md`, current git state, benchmark source/docs, and recent PRD handoffs.
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
2. Inspect git history, working tree, benchmark runner/source, docs, captured benchmark outputs or summaries, and any Linux-host blocker/follow-up status.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence or explicit deferred/blocker status.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- `zig build test` result is recorded.
- Benchmark matrix quick smoke result is recorded.
- macOS fallback baseline status is recorded separately from Linux `io_uring` status.
- Linux `io_uring` verification either has real Linux-host evidence or an explicit blocker/follow-up card.
- Working tree status is recorded, with unrelated/untracked files called out.
- No generated benchmark/database/WAL/log artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, benchmark matrix results, Linux verification status, remediation status, and remaining risks to write the next PRD under `docs/prds/`.
2. Decide whether the next highest-leverage workstream is WAL truncation optimization, compaction performance optimization, read-path/server throughput work, or more verification infrastructure.
3. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
4. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
5. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Benchmark matrix runner

Objective: Add a repeatable matrix workflow that runs the native benchmark over a small set of modes, batch sizes, value sizes, and read APIs while preserving the existing one-shot benchmark command.

Candidate tasks:

- Add a repository-local runner, for example under `bench/`, that invokes `zig build -Doptimize=ReleaseFast benchmark -- ... --json` for matrix rows.
- Include a cheap `--quick` or default smoke profile suitable for reviewers and final audits.
- Cover at least these dimensions in the documented default/full profile: `memory` vs `persisted`, batch sizes `1`, `16`, and `64`, value sizes `16` and `256`, and read APIs `get` and `get-into` where meaningful.
- Use unique `/tmp/...` database paths for persisted rows and clean up `.wal` files.
- Emit machine-readable aggregate output, preferably JSON Lines plus a compact JSON or Markdown summary.
- Keep the existing `bench/json-smoke.sh` behavior compatible or intentionally supersede it with docs.

Likely files:

- `bench/benchmark-matrix.*` or `bench/phage-benchmark-matrix.*`
- `bench/json-smoke.sh`
- `build.zig` if adding a `benchmark-matrix` build step is the smallest stable workflow
- `src/benchmark.zig` only if runner support requires small metadata/schema additions
- tests or fixtures if a parser/aggregator helper is added

Acceptance criteria:

- A single documented command runs a cheap matrix smoke locally without leaving repo-local database/WAL artifacts.
- Matrix output includes row-level JSON data with mode, operation count, value size, batch size, read API, throughput, and latency percentiles.
- Persisted rows use disposable paths and clean up generated stores/WALs.
- Existing one-shot benchmark commands still work.
- `zig build test` passes.

Expected commits:

- `feat(benchmark): add benchmark matrix runner`
- `test(benchmark): cover matrix output parsing` if parser tests are added separately

### S2: Benchmark metadata and comparability

Objective: Make matrix results self-describing enough that macOS fallback, Linux `io_uring`, Zig version, git revision, and benchmark profile are not confused in later optimization decisions.

Candidate tasks:

- Add metadata to runner output: git revision, OS/platform, Zig version, command/profile, timestamp, and whether the run is macOS POSIX fallback or intended Linux backend evidence.
- If backend selection is visible from source, include backend name in benchmark output or summary; otherwise document the inference and avoid overclaiming.
- Validate machine-readable output with `python3 -m json.tool`, a small test, or a deterministic parser check.
- Keep human output readable and avoid changing the existing benchmark JSON schema incompatibly unless docs/review justify it.

Likely files:

- `bench/benchmark-matrix.*`
- `src/benchmark.zig` if benchmark JSON metadata is emitted by Zig
- `docs/GETTING_STARTED.md`
- `docs/MVP_ROADMAP.md`
- optional parser tests under `bench/` or Zig test modules

Acceptance criteria:

- Matrix output or summary records enough metadata to distinguish macOS fallback from Linux `io_uring` runs.
- JSON output remains parseable by standard tooling.
- Docs explain which fields are stable automation fields and which are informational metadata.
- `zig build test` passes.

Expected commits:

- `feat(benchmark): include matrix run metadata`
- `docs(benchmark): document benchmark result metadata`

### S3: macOS fallback baseline capture and documentation

Objective: Capture a small local baseline with the new runner and document how to interpret macOS fallback numbers without treating them as final Linux performance.

Candidate tasks:

- Run the quick matrix profile on the current macOS environment.
- Summarize a few representative rows in docs without committing large raw artifacts.
- Update benchmark docs so agents and humans can reproduce the baseline and compare future runs.
- Keep docs explicit that macOS persisted numbers exercise the POSIX fallback, not Linux `io_uring`.

Likely files:

- `docs/GETTING_STARTED.md`
- `docs/MVP_ROADMAP.md`
- optional small summary under `docs/benchmarks/`
- `README.md` if the benchmark command list changes

Acceptance criteria:

- A quick matrix smoke result is recorded in a human-readable doc or review handoff.
- Docs include copy-paste commands for quick and fuller benchmark profiles.
- Docs state that generated raw result files should remain untracked unless a ticket explicitly approves a small summary artifact.
- `git status --short --untracked-files=all` is recorded after the run.

Expected commits:

- `docs(benchmark): document matrix benchmark workflow`
- `docs(benchmark): record macOS fallback baseline` if a small baseline summary is committed

### S4: Linux io_uring verification path

Objective: Use the matrix workflow to obtain or precisely gate final Linux `io_uring` backend performance evidence.

Candidate tasks:

- Determine whether the worker environment is Linux with `io_uring` support or otherwise has access to an approved Linux execution path.
- If Linux is available, run the quick matrix and at least one fuller persisted profile with disposable paths.
- If Linux is not available, write a concise runbook/follow-up with the exact command(s), expected artifacts, and blocker reason.
- Do not fabricate Linux numbers from macOS fallback output.
- Preserve raw large outputs outside git unless a small curated summary is explicitly committed.

Likely files:

- `docs/GETTING_STARTED.md`
- `docs/MVP_ROADMAP.md`
- optional `docs/benchmarks/2026-05-18-linux-io-uring-verification.md`
- `bench/benchmark-matrix.*` if runner fixes are needed from Linux execution

Acceptance criteria:

- Linux status is one of: `verified with evidence`, `blocked waiting for Linux host`, or `deferred with a remediation card`.
- Any Linux result summary names OS/kernel, Zig version, git revision, command/profile, and key throughput/latency rows.
- If blocked, the block/follow-up names the exact missing capability and the command to run once available.
- No generated stores/WALs/logs are staged.

Expected commits:

- `docs(benchmark): record linux io_uring verification` if Linux evidence is available
- `docs(benchmark): add linux verification runbook` if no Linux host is available

### S5: Optimization decision handoff

Objective: Make the next storage optimization PRD evidence-driven rather than speculative.

Candidate tasks:

- Read S1-S4 outputs and identify whether persisted write latency, WAL truncation, compaction, read allocation, or server overhead is the most compelling next bottleneck.
- Do not implement the optimization in this PRD.
- Feed the recommendation into Gate 2 and Gate 3 so the next PRD can target a concrete bottleneck.

Likely files:

- reviewer handoff comments
- optional `docs/MVP_ROADMAP.md` status note
- next PRD under `docs/prds/` during Gate 3

Acceptance criteria:

- Final audit includes a recommendation for the next optimization PRD based on matrix evidence.
- If evidence is insufficient, the audit creates remediation cards instead of guessing.

Expected commits:

- Usually none for this slice unless docs status is updated.

## Verification commands

Minimum local correctness check for implementation cards:

```sh
git status --short --untracked-files=all
zig fmt src build.zig
zig build test
```

Benchmark runner checks once S1/S2 are implemented; exact command may differ if the implementation chooses a build step, but it must be documented:

```sh
bench/benchmark-matrix.sh --quick --output /tmp/phage-benchmark-matrix.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-summary.json
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --db-path /tmp/phage-prd-bench --json
```

Server workflow should remain intact but is not the focus of this PRD:

```sh
zig build --help
zig build run-server -- --help
zig build server-smoke -- --db-path /tmp/phage-server-smoke
```

Linux verification, only on an appropriate Linux host:

```sh
bench/benchmark-matrix.sh --profile linux-io-uring --output /tmp/phage-linux-io-uring-matrix.jsonl
```

## Completion criteria

This PRD is complete when:

- Gate 1 decomposed this PRD into valid Kanban tickets.
- Accepted implementation slices are completed or explicitly deferred with evidence and remediation cards.
- Review cards approved implementation or created remediation cards.
- Gate 2 produced an evidence-based final gap check distinguishing macOS fallback from Linux `io_uring` status.
- Gate 3 generated the next PRD and queued the next available work.

## Related documents

- [Overnight Phage Work PRD](2026-05-18-overnight-phage-work-prd.md)
- [Phage Server Build and Runtime Verification PRD](2026-05-18-phage-server-build-runtime-prd.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [Getting Started](../GETTING_STARTED.md)
- [README](../../README.md)
