# PRD: Phage WAL Write-Path Optimization

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Use the benchmark matrix evidence to improve Phage's persisted write path, with a specific focus on WAL commit/clear overhead, while preserving crash-recovery correctness and keeping Linux `io_uring` verification explicit rather than inferred from macOS fallback numbers.

## Background

The benchmark matrix and Linux verification PRD produced the repeatable measurement workflow that earlier optimization candidates needed. Gate 2 approved the matrix, macOS fallback baseline, documentation, and final audit while recording one remaining Linux correctness blocker:

- Current HEAD at PRD planning time: `bc23f18 fix(io): handle io_uring empty-value recovery reads`.
- Gate 2 recommendation: prioritize Linux re-verification / closing `t_c54e96cd` before declaring optimization wins; once Linux correctness is green, the matrix points to the persisted write/WAL path as the strongest next optimization candidate.
- Existing Linux remediation card `t_c54e96cd` has a committed fix for the empty-value `io_uring` read failure, but is blocked because OrbStack is stopped and `phage-linux` start/info times out. Its remaining verification is Linux `zig build test` plus a quick Linux `io_uring` matrix rerun.
- macOS fallback remains useful for local correctness and regression smokes, but persisted macOS numbers must not be relabeled as Linux performance.

Fresh Gate 3 planning checks on 2026-05-18 found the same tracked working tree state plus known unrelated untracked files (`AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, `docs/prds/_template.md`). A quick matrix smoke at `bc23f18` produced:

- `bench/benchmark-matrix.sh --quick --ops 1000 --output /tmp/phage-gate3-next-prd-1779113820.jsonl`
- Summary validated with `python3 -m json.tool`.
- `metadata.backend_status=macos-posix-fallback`, `row_count=2`, `rows_by_mode.memory=1`, `rows_by_mode.persisted=1`.
- Memory row: total `6.21M ops/sec`, write `3.70M ops/sec`, read `19.23M ops/sec`, write p95 `0.44us`, read p99 `1.00us`.
- Persisted row: total `0.96M ops/sec`, write `0.81M ops/sec`, read `1.18M ops/sec`, write p95 `1.50us`, read p99 `1.00us`.
- Persisted store/WAL artifacts were created under `/tmp/phage-benchmark-matrix-*` and cleaned up by the runner.

The Linux `io_uring` verification doc records useful but not final-all-green Linux matrix evidence:

- Quick Linux matrix smoke: `metadata.backend_status=linux-io-uring-intended`, `row_count=2`.
- Fuller `--profile linux-io-uring --ops 1000`: `row_count=24`, `rows_by_mode.memory=12`, `rows_by_mode.persisted=12`.
- Representative rows include memory best total `11.90M ops/sec`, persisted small-batch total `0.25M ops/sec`, and persisted batch-64 total `0.63M ops/sec`.
- Linux `zig build test` was not green at that revision because of the WAL empty-value recovery failure now fixed in `bc23f18` but not re-verified on Linux.

Source inspection shows the likely optimization surface:

- `src/root.zig` `put` and `putBatch` write data and WAL entries through the backend, wait for I/O, update the index, then call `Wal.clear`.
- `src/io/wal.zig` `Wal.clear` currently calls `ftruncate(wal_fd, 0)`, `lseek_SET(wal_fd, 0)`, and `fsync(wal_fd)`, then resets the tracked WAL size.
- `putBatch` already clears once per batch, so any optimization should distinguish single-write, batch-write, and crash-recovery behavior instead of blindly removing correctness safeguards.

## Primary goal

Reduce persisted write-path latency or throughput gap in a measurable, crash-safe way by profiling and optimizing WAL commit/clear behavior. The accepted work must provide before/after matrix evidence, regression tests for recovery semantics, and separate macOS fallback vs Linux `io_uring` status.

## Non-goals

- Do not weaken crash recovery or remove WAL clear/durability semantics without explicit tests and reviewer evidence.
- Do not claim Linux `io_uring` performance wins from macOS POSIX-fallback output.
- Do not duplicate or replace existing remediation card `t_c54e96cd`; depend on it for post-fix Linux correctness where needed.
- Do not rewrite the storage format, index layout, server concurrency model, ZeroMQ protocol, or benchmark matrix runner wholesale.
- Do not commit raw JSONL, summary JSON, database files, WAL files, `.compact.tmp` files, logs, or machine-specific artifacts.
- Do not change local user, Hermes, Zig, package-manager, OrbStack, or machine configuration.
- Do not hide benchmark regressions by reducing operation counts below the PRD commands unless a card explicitly documents a cheap smoke override.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only and preserve unrelated/untracked files, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, and `docs/prds/_template.md`.
- Run `zig fmt src build.zig` for touched Zig files where appropriate.
- Run `zig build test` before implementation slices are considered complete.
- Keep persisted benchmark paths under `/tmp/...`; verify runner cleanup when benchmarks are run.
- Prefer deterministic tests for WAL clear/recovery behavior before performance changes.
- Keep benchmark evidence human-readable in docs or Kanban handoffs; leave raw run artifacts out of git unless a later ticket explicitly approves a small curated summary.
- If Linux is unavailable, block or defer the Linux verification slice with the exact host/tool error instead of fabricating numbers.

## Required gates

This PRD follows the Gate 1 / Gate 2 / Gate 3 loop pattern used by the prior Phage PRDs.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, current git state, benchmark matrix evidence, Linux remediation status, and repository guidance.
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
2. Inspect git history, working tree, WAL/source changes, tests, benchmark evidence, docs, and Linux remediation/verification status.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence or explicit deferred/blocker status.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- `zig build test` result is recorded.
- WAL/recovery regression evidence is recorded for any changed commit/clear behavior.
- Before/after persisted benchmark evidence is recorded, with macOS fallback and Linux `io_uring` status separated.
- Existing `t_c54e96cd` status is read; Linux post-fix verification is either real evidence or an explicit blocker/deferred card.
- Working tree status is recorded, with unrelated/untracked files called out.
- No generated benchmark/database/WAL/log artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, benchmark deltas, Linux verification status, remediation status, and remaining risks to write the next PRD under `docs/prds/`.
2. Decide whether the next highest-leverage workstream is deeper WAL optimization, compaction performance, read-path/server throughput, or Linux verification infrastructure.
3. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
4. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
5. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Profile WAL write/clear cost and establish accepted baselines

Objective: Add or use minimal instrumentation so optimization work has a stable before/after baseline for persisted writes, WAL clear/truncate behavior, and batch-size effects.

Candidate tasks:

- Add a focused benchmark mode, benchmark metadata field, or small measurement helper only if existing matrix output cannot isolate the WAL clear path enough for review.
- Capture before-change persisted baselines for at least batch sizes `1`, `16`, and `64` with value size `16` and read API `get-into`.
- Record `put` vs `putBatch` implications in the handoff or docs.
- Keep matrix output parseable by `python3 -m json.tool` and preserve existing one-shot benchmark behavior.

Likely files:

- `bench/benchmark-matrix.sh`
- `bench/benchmark_matrix.py`
- `src/benchmark.zig`
- `src/root.zig`
- optional docs under `docs/benchmarks/`

Acceptance criteria:

- Baseline evidence names commit, platform, Zig version, backend status, command, operation count, batch size, value size, throughput, and p50/p95/p99 write latency.
- Any new instrumentation has deterministic test coverage or a deterministic parser/JSON validation check.
- Existing quick matrix smoke still passes and cleans persisted artifacts.
- `zig build test` passes.
- No raw benchmark artifacts are staged.

Expected commits:

- `test(benchmark): cover WAL write-path baseline metadata` if tests are added first.
- `feat(benchmark): expose WAL write-path baseline evidence` if source/runner support is added.
- `docs(benchmark): record WAL write-path baseline` if a curated summary is committed.

### S2: Optimize WAL clear/truncation without relaxing recovery guarantees

Objective: Reduce unnecessary WAL clear overhead on the committed persisted write path while proving that crash-recovery semantics remain intact.

Candidate tasks:

- Write focused tests around `Wal.clear`, `put`, `putBatch`, empty values, delete entries, corrupt/incomplete WAL tails, and recovery after committed data writes.
- Investigate safe no-op or reduced-work paths such as skipping clear when the tracked WAL size is already zero, avoiding redundant seek work, batching clear behavior, or otherwise reducing per-write overhead without changing the persistence contract.
- Preserve existing `putBatch` behavior and do not regress batch writes.
- Document any durability assumptions in code comments or docs if the change clarifies the current contract.

Likely files:

- `src/io/wal.zig`
- `src/root.zig`
- `src/io/backend.zig` only if backend behavior is directly involved
- tests embedded in touched Zig modules
- optional `docs/MVP_ROADMAP.md` or `docs/benchmarks/...` for behavior notes

Acceptance criteria:

- New or existing WAL/recovery tests fail before the behavior change where practical and pass after.
- `zig build test` passes on macOS POSIX fallback.
- Quick persisted benchmark evidence is captured after the change.
- The implementation does not delete crash-recovery coverage for committed, partial, corrupt, empty-value, or delete WAL entries.
- No generated `.db`, `.wal`, `.compact.tmp`, JSONL, summary JSON, or log artifacts are staged.

Expected commits:

- `test(io): cover WAL clear recovery invariants`
- `perf(io): reduce WAL clear overhead`

### S3: Document before/after persisted write evidence

Objective: Make the optimization result auditable without committing raw benchmark artifacts.

Candidate tasks:

- Record a small curated before/after table for macOS POSIX fallback using the matrix commands from S1/S2.
- If Linux is available through the dependency chain, add a Linux `io_uring` table; otherwise explicitly mark Linux evidence deferred to the Linux verification slice.
- Update docs so future Gate 3 planning can compare persisted write-path changes against this PRD.

Likely files:

- `docs/benchmarks/<date>-wal-write-path-optimization.md`
- `docs/MVP_ROADMAP.md`
- `docs/GETTING_STARTED.md` only if commands or workflow changed

Acceptance criteria:

- Docs separate macOS fallback evidence from Linux `io_uring` evidence.
- Docs include exact commands, commit revisions, backend status, row counts, representative throughput, and write latency percentiles.
- Raw JSONL/summary/database/WAL artifacts remain out of git.
- Markdown relative links to the PRD, benchmark docs, and roadmap are valid.

Expected commits:

- `docs(benchmark): record WAL write-path optimization evidence`

### S4: Re-verify Linux correctness and `io_uring` persisted write status

Objective: After the existing Linux remediation is unblocked/completed, verify that the optimized WAL write path is correct and measured on Linux `io_uring`.

Candidate tasks:

- Read existing card `t_c54e96cd` and avoid duplicating its blocked work.
- Run Linux `uname -a`, `zig version`, `zig build test`, quick matrix smoke, and a cheap `linux-io-uring` profile from a real Linux host.
- Record whether the new WAL optimization changes representative persisted write latency/throughput on Linux.
- If Linux remains unavailable, block with the exact OrbStack/host error and keep macOS evidence clearly labeled.

Likely files:

- `docs/benchmarks/2026-05-18-linux-io-uring-verification.md`
- `docs/benchmarks/<date>-wal-write-path-optimization.md`
- optional `docs/MVP_ROADMAP.md`

Acceptance criteria:

- Linux `zig build test` after `bc23f18` and after this PRD's optimization either passes with evidence or has a precise blocker.
- Linux quick matrix summary validates with `python3 -m json.tool` and records `metadata.backend_status=linux-io-uring-intended`, or the blocker says exactly why it could not run.
- The handoff does not treat macOS POSIX fallback as Linux `io_uring` evidence.
- No generated artifacts are staged.

Expected commits:

- `docs(benchmark): record Linux WAL write-path verification` if Linux evidence is collected.

## Final completion criteria

This PRD is complete only when Gate 2 records evidence for all of the following:

- WAL write-path optimization work either improved or explicitly did not improve persisted write metrics, with before/after evidence.
- WAL/recovery tests and `zig build test` pass for accepted source changes.
- macOS fallback evidence is clearly labeled and not overclaimed.
- Linux `io_uring` correctness/performance status is either verified after `t_c54e96cd` or explicitly deferred with a blocker/remediation card.
- Documentation or handoffs contain enough exact commands and commit IDs for the next planner to choose the next workstream.
- Working tree and staged changes are clean except for intentional committed source/docs changes.

## Suggested Kanban decomposition

- S1 implementation: `phage-worker`, parent Gate 3 planner card.
- S1 review: `reviewer`, parent S1 implementation.
- S2 implementation: `phage-worker`, parent S1 review.
- S2 review: `reviewer`, parent S2 implementation.
- S3 documentation/evidence: `phage-worker`, parent S2 review.
- S3 review: `reviewer`, parent S3 implementation.
- S4 Linux verification: `phage-worker`, parents S2 review and existing remediation card `t_c54e96cd`.
- S4 review: `reviewer`, parent S4 implementation.
- Gate 2 final audit: `reviewer`, parents all review cards.
- Gate 3 continuation planning: `planner`, parent Gate 2 final audit.

## Related documents

- [Benchmark matrix and Linux io_uring verification PRD](2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
- [macOS POSIX-fallback benchmark baseline](../benchmarks/2026-05-18-macos-fallback-baseline.md)
- [Linux io_uring benchmark verification](../benchmarks/2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
