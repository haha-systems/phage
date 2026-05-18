# PRD: Phage Redis/Valkey Comparison Benchmarks

Date: 2026-05-18
Status: Draft, ready for Kanban execution
Owner: Hermes / coding-agent fleet
Repository: `/Users/xiy/code/phage`

## Purpose

Create a reproducible, respectful, apples-to-apples local benchmark workflow that compares Phage against Redis and Valkey without mixing incomparable benchmark categories, overstating Phage's maturity, or committing generated artifacts.

## Background

Phage now has several benchmark and server-measurement surfaces that must stay distinct:

- Native Phage core benchmarks run in-process through `zig build -Doptimize=ReleaseFast benchmark -- ...` and can measure memory or persisted storage modes with value size, batch size, read API, latency percentiles, and throughput.
- The benchmark matrix workflow (`bench/benchmark-matrix.sh`) records curated Phage core rows with git/Zig/OS/platform/profile/backend metadata and keeps raw JSONL/summary artifacts under `/tmp`.
- Server-load evidence now exists for the ZeroMQ server through `zig build -Doptimize=ReleaseFast server-load -- ...`, with bounded multi-client request/reply traffic, p50/p95/p99 latency, request mix, backend status, runtime model, shutdown metrics, and artifact cleanup.
- The current Phage server runtime is still `multi-client-serialized-req-rep`: it accepts multiple ZeroMQ REQ clients, but one REP loop serializes command execution. Multi-client rows are queueing/request-reply evidence, not proof of parallel command execution.
- Recent timeout hardening for `src/server/harness.zig`, `src/server/load_smoke.zig`, `src/server/smoke.zig`, and `src/server/sustained_smoke.zig` was approved at commit `f3e8a00a489083bdaed873c3b314f067fd5bbd24`; required tests and smokes passed, and request caps were unchanged.
- `src/server/load_smoke.zig` currently caps `--clients` at 32 and `--clients * --requests` at 2,000. Comparison work must respect those caps unless a separate accepted card changes them first.
- Existing curated evidence separates macOS POSIX-fallback rows from Linux `io_uring` rows. A local macOS comparison should be labeled as local macOS development evidence and must not be relabeled as Linux backend evidence.

Redis and Valkey are mature, production-hardened reference systems with extensive benchmark tooling and years of operational optimization. This PRD uses them as reference points for measurement discipline and local context, not as strawmen and not as a claim that Phage is generally faster, safer, or more feature-complete.

## Primary goal

Add a reproducible local macOS comparison benchmark workflow and curated evidence note that separates Phage core, Phage server-load, Redis/Valkey native benchmark-tool, and Redis/Valkey custom mixed-workload results while preserving artifact hygiene and conservative interpretation.

## Non-goals

- Do not run or claim a full production benchmark campaign in the PRD/decomposition card.
- Do not claim Phage beats Redis or Valkey overall, in production, under Linux `io_uring`, under cluster/replica workloads, or under durability settings not actually measured.
- Do not compare Phage in-process core benchmark rows directly against Redis/Valkey network-server rows as if they measure the same thing.
- Do not run persistent Homebrew, launchd, Docker, OrbStack, or system background services for Redis/Valkey. Use disposable local processes, disposable ports, and temporary directories.
- Do not change local user, Hermes, shell, Homebrew, launchd, Redis, Valkey, ZeroMQ, Zig, or machine configuration.
- Do not raise current Phage server-load request/client caps in this PRD. If higher server-load counts are needed, create and approve a separate harness-capacity card first.
- Do not add broad protocol compatibility layers, RESP support in Phage, clustered Redis/Valkey tests, replication, TLS, persistence-tuning matrices, or multi-machine benchmarks.
- Do not commit raw benchmark output, JSON/JSONL/summary artifacts, database files, WAL files, Redis/Valkey appendonly/RDB files, logs, pid files, Homebrew metadata, temporary directories, or generated machine-specific artifacts.
- Do not collapse harness/setup, comparison runs, docs, review, final audit, and next-PRD planning into one commit.

## Operating constraints

- Use small implementation slices with Conventional Commit messages.
- Stage explicit paths only and preserve unrelated/untracked files, including `AGENTS.md`, `docs/prds/2026-05-18-overnight-phage-work-prd.md`, `docs/prds/_template.md`, and generated-looking `matrix.json-summary.json`.
- Pin the Phage subject under test by recording either the exact git SHA under test or an isolated temporary worktree/clone path plus SHA. Do not silently benchmark a dirty tree.
- Record Redis and Valkey versions, absolute binary paths, and command-line invocations. If a binary is unavailable, block or record the exact missing-tool status instead of fabricating results.
- Record host metadata: timestamp, `uname -a`, macOS version where available, CPU architecture, Zig version, libzmq status when Phage server-load is involved, Redis version, Valkey version, and relevant binary paths.
- Record backend and durability status for every row: Phage `memory` vs `persisted`, Phage `backend_status`, Redis/Valkey `save`/RDB/AOF settings, append-only mode, temporary data directory, and whether data was persisted to disk.
- Record payload size, key/value shape, client count, request count, pipeline/batch settings, read/write/delete/ping mix, warmup behavior if any, and whether results are single-run smoke evidence or repeated measurements.
- Keep Phage core/in-process benchmark numbers, Phage server-load numbers, Redis/Valkey native benchmark-tool numbers, and Redis/Valkey custom mixed-workload numbers in separate tables/sections.
- Respect current Phage server-load caps: no server-load run may exceed 32 clients or 2,000 total requests until a separate accepted card changes those caps.
- Use disposable `/tmp/...` database/log/output paths and verify cleanup for Phage, Redis, and Valkey artifacts after runs.
- Prefer scripts or documented commands that fail closed when tools are missing, ports are occupied, paths are unsafe, JSON cannot be parsed, cleanup fails, or benchmark categories would be mixed.
- Keep raw run artifacts under `/tmp`; commit only small curated Markdown evidence and source/docs needed to reproduce.

## Required benchmark categories

The comparison workflow must explicitly separate these categories:

1. **Phage core/in-process benchmark numbers**
   - Source: `zig build -Doptimize=ReleaseFast benchmark -- ...` or `bench/benchmark-matrix.sh`.
   - Required labels: `category=phage-core-in-process`, mode (`memory` or `persisted`), backend status, value size, batch size, read API, operation count, profile, git SHA, and whether the row is local macOS POSIX fallback or Linux evidence.
   - Interpretation: useful for storage-engine fast-path context only; not directly comparable to Redis/Valkey network server rows.

2. **Phage server-load numbers**
   - Source: `zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/... --clients N --requests M --json`.
   - Required labels: `category=phage-server-load`, runtime model, backend status, client count, requests per client, total requests, deterministic request mix, latency percentiles, throughput, shutdown metrics, cleanup status, git SHA, and cap compliance.
   - Interpretation: current rows measure bounded ZeroMQ REQ/REP through a serialized server loop.

3. **Redis/Valkey native benchmark-tool numbers**
   - Source: `redis-benchmark` / `valkey-benchmark` or equivalent binaries from absolute paths.
   - Required labels: `category=redis-native-benchmark` or `category=valkey-native-benchmark`, server binary path/version, benchmark binary path/version, temporary port, temporary dir, persistence settings, command mix selected by the native tool, client count, request count, pipeline setting, payload size, and cleanup status.
   - Interpretation: native tooling is valuable reference evidence, but its built-in command mix and protocol/runtime are not the same as Phage server-load unless explicitly matched.

4. **Redis/Valkey custom mixed workload matching Phage where possible**
   - Source: a small repository-local script/tool or documented command sequence that drives Redis/Valkey with a Phage-like request mix (`PING`, `SET`, `GET`, `DEL`) and comparable bounded counts.
   - Required labels: `category=redis-custom-mixed` or `category=valkey-custom-mixed`, client count, requests per client, total requests, command counts, payload size, pipeline/batching settings, server persistence settings, latency percentiles if collected, throughput, error count, and cleanup status.
   - Interpretation: this is the closest local network-server comparison to Phage server-load, but it must still disclose protocol/runtime differences and avoid broad product claims.

## Required gates

This PRD follows the Gate 1 / Gate 2 / Gate 3 loop pattern used by prior Phage PRDs.

### Gate 1: Decompose this PRD into Kanban tickets

Owner: `planner`

Required actions:

1. Discover available Hermes profiles with `hermes profile list`.
2. Read this PRD, `AGENTS.md`, current git state, benchmark docs, server throughput docs, server concurrency status, server-load caps, and the approved timeout-hardening handoff.
3. Create implementation cards for the accepted work slices below.
4. Create review/docs-review cards with parent dependencies so review cannot run before implementation/comparison evidence exists.
5. Create a Gate 2 final PRD gap-audit card that depends on the docs/evidence review.
6. Create a Gate 3 continuation-planning card that depends on Gate 2.
7. Include autonomy policy, PRD slice IDs, likely files, verification commands, expected Conventional Commit message, and staging hygiene in every code- or docs-changing ticket.

Gate 1 acceptance criteria:

- Kanban cards exist for benchmark-harness/setup, run/collect evidence, docs/review, final PRD audit, and continuation planning.
- Actual comparison runs are gated after timeout hardening and after setup/harness checks pass.
- The planner summary names this PRD path and all created card IDs.

### Gate 2: Final gap check against this PRD

Owner: `reviewer`

Required actions:

1. Read this PRD line-by-line.
2. Inspect current git history, working tree, comparison harness/scripts/docs, curated benchmark evidence, setup/tool checks, and artifact hygiene.
3. Produce a requirement/evidence/status/remediation table.
4. Create remediation Kanban tickets for unmet accepted requirements rather than claiming completion.
5. Complete only when every accepted requirement has evidence, explicit missing-tool/deferred status, or remediation cards.

Gate 2 acceptance criteria:

- Audit includes a table with requirement, evidence, status, and remediation card if needed.
- The four benchmark categories above are present as separate sections or explicitly marked blocked/deferred with exact reasons.
- Evidence records pinned Phage SHA/worktree, Redis/Valkey versions and absolute paths, host/OS metadata, backend status, durability mode, payload size, client counts, request counts, pipeline/batching settings, and cleanup status.
- Phage server-load comparison counts respect the current caps unless a separate accepted card changed them.
- Redis/Valkey were run as disposable local processes on temporary ports/dirs, not persistent services.
- Working tree status is recorded, with unrelated/untracked files called out.
- No raw benchmark output, database/WAL/RDB/AOF/log/pid files, Homebrew metadata, or generated artifacts are staged.

### Gate 3: Generate the next PRD and start the next loop

Owner: `planner`

Required actions:

1. Use Gate 2 output, completed commits, comparison evidence, blockers, and remaining risks to write the next PRD under `docs/prds/`.
2. Decide whether the next highest-leverage workstream is benchmark-capacity hardening, protocol compatibility, Linux comparison infrastructure, Redis/Valkey mixed-workload refinement, storage/server optimization, or another measured bottleneck.
3. Decompose the new PRD into implementation, review, final-audit, and continuation cards.
4. Leave next available work in `ready` state with valid assignees/dependencies and `dir:/Users/xiy/code/phage` workspace.
5. Block only if no useful next work should start or an irreducible human decision is needed.

## Work slices

### S1: Build disposable Redis/Valkey comparison setup and harness checks

Objective: Add the minimal repository-local workflow needed to discover Redis/Valkey binaries, start disposable local server processes, validate versions/ports/temp dirs, and prove cleanup without running the full comparison.

Candidate tasks:

- Add a small script or documented command workflow under `bench/` for comparing local Phage, Redis, and Valkey without using persistent services.
- Discover binaries through explicit environment variables or PATH lookup, but record absolute resolved paths in output/evidence.
- Start Redis/Valkey with disposable `--port`, temporary dir, disabled or explicitly documented persistence settings, and log/pid files under `/tmp`.
- Ensure setup checks fail closed if ports are occupied, binaries are missing, versions cannot be read, temporary dirs are unsafe, a server cannot be terminated, or cleanup leaves artifacts.
- Include dry-run or setup-only mode so reviewers can validate process lifecycle without collecting full benchmark results.
- Keep Homebrew metadata, package-manager output, temp dirs, logs, and pid files out of git.

Likely files:

- `bench/redis-valkey-comparison.py` or `bench/redis_valkey_comparison.py`
- `bench/test_redis_valkey_comparison.py`
- `docs/benchmarks/2026-05-18-redis-valkey-comparison.md` only if setup status needs a curated note in this slice
- `docs/MVP_ROADMAP.md` only for a concise status link if accepted by the implementer/reviewer

Acceptance criteria:

- A setup/dry-run command records or validates Phage SHA/worktree, host metadata, Redis/Valkey binary paths and versions when available, temporary ports, temporary dirs, and intended persistence settings.
- Redis/Valkey are not installed, upgraded, configured as services, or launched persistently by the workflow.
- Unit tests or deterministic dry-run tests cover missing binaries, unsafe paths, category labeling, and cleanup behavior where practical.
- `python3 -m unittest bench/test_redis_valkey_comparison.py` passes if a Python harness is added.
- `zig build test` passes unless the card explicitly documents a docs/script-only verification subset.
- `git diff --check` passes.
- No raw benchmark output, database/WAL/RDB/AOF/log/pid/temp artifacts, Homebrew metadata, or generated summaries are staged.

Expected commits:

- `test(bench): cover Redis Valkey comparison harness setup`
- `feat(bench): add disposable Redis Valkey comparison harness`

### S2: Run bounded local comparison and curate evidence

Objective: Use the approved setup workflow to collect a small, bounded local macOS comparison while keeping Phage core, Phage server-load, Redis/Valkey native, and Redis/Valkey custom mixed-workload results separate.

Prerequisite: S1 setup/harness checks and review approval.

Candidate tasks:

- Record `git status --short --untracked-files=all`, pinned Phage SHA or isolated worktree path/SHA, timestamp, `uname -a`, macOS version where available, Zig version, libzmq status, Redis version/path, Valkey version/path, and all command invocations.
- Run Phage core/in-process rows with clearly labeled `memory` and/or `persisted` modes and keep raw output under `/tmp`.
- Run Phage server-load rows with counts within current caps, for example no more than 2,000 total requests and no more than 32 clients.
- Run Redis/Valkey native benchmark-tool rows with comparable payload/client/request/pipeline settings where possible, but keep them in a separate native-tool section.
- Run Redis/Valkey custom mixed workload rows that best match the Phage server-load request mix and bounded counts where possible.
- Write a curated Markdown evidence note that treats Redis and Valkey as mature reference systems, discloses all mismatches, and avoids product-level winner claims.
- Verify all temp DB/WAL/RDB/AOF/log/pid/output paths are removed or left only under `/tmp` and unstaged.

Likely files:

- `docs/benchmarks/2026-05-18-redis-valkey-comparison.md`
- `bench/redis-valkey-comparison.py` or `bench/redis_valkey_comparison.py` only for small fixes discovered during the run
- `docs/MVP_ROADMAP.md` only for a concise status link if evidence is accepted

Acceptance criteria:

- Curated evidence has four separate sections/tables for Phage core, Phage server-load, Redis/Valkey native benchmark-tool, and Redis/Valkey custom mixed workload results.
- Every row records payload size, client count, request count, pipeline/batching setting, persistence/durability mode, backend/runtime status, command mix, throughput, latency fields available from the tool, error/cleanup status, and source command.
- Phage server-load rows respect current caps and record cap compliance.
- Redis/Valkey server processes are disposable and cleaned up; no persistent services are used.
- If Redis or Valkey is unavailable, the evidence note records the exact missing-tool status and the worker creates remediation/setup follow-up cards if useful.
- `python3 -m json.tool` or harness validation checks pass for any raw JSON that is produced.
- `git diff --check` passes.
- `zig build test` or a documented docs/script-only verification subset passes.
- No raw benchmark output or generated artifacts are staged.

Expected commit:

- `docs(benchmark): record local Redis Valkey comparison evidence`

### S3: Review comparison docs, claims, and artifact hygiene

Objective: Review the harness/setup and curated evidence for reproducibility, fairness, conservative interpretation, and clean staging before final PRD audit.

Candidate tasks:

- Read this PRD, the S1/S2 handoffs, changed scripts/docs, and curated benchmark note.
- Verify Redis/Valkey are framed respectfully as mature reference systems.
- Verify benchmark categories are separated and not compared as equivalent where they are not.
- Verify Phage server-load counts respect caps and actual runtime model labels.
- Verify pinned Phage SHA/worktree, Redis/Valkey absolute paths/versions, host metadata, backend/durability status, payload size, client/request counts, pipeline/batching, and cleanup status are present.
- Check git status and staged files for raw outputs or generated artifacts.
- Create remediation cards for missing fields, misleading claims, setup gaps, or artifact hygiene issues.

Likely files:

- `docs/benchmarks/2026-05-18-redis-valkey-comparison.md`
- `bench/redis-valkey-comparison.py` or `bench/redis_valkey_comparison.py`
- `bench/test_redis_valkey_comparison.py`
- `docs/MVP_ROADMAP.md` if touched

Acceptance criteria:

- Review handoff lists findings with severity and remediation card IDs if needed.
- Review approves only if claims are conservative, categories are separated, setup is disposable, and staging hygiene is clean.
- `git diff --check` result is recorded.
- `git status --short --untracked-files=all` result is recorded.
- No generated artifacts are staged.

Expected commit:

- None for review-only approval, or `docs(benchmark): clarify Redis Valkey comparison claims` if a small reviewer-owned docs correction is explicitly made.

## Verification commands

Minimum local correctness and hygiene checks:

```sh
git status --short --untracked-files=all
git log --oneline -20
git diff --check
zig build test
python3 -m unittest bench/test_redis_valkey_comparison.py
```

Setup/dry-run command shape, to be finalized by S1:

```sh
python3 bench/redis-valkey-comparison.py --setup-only --output /tmp/phage-redis-valkey-setup.json
python3 -m json.tool /tmp/phage-redis-valkey-setup.json >/dev/null
```

Phage core examples:

```sh
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json > /tmp/phage-rv-core-memory.json
python3 -m json.tool /tmp/phage-rv-core-memory.json >/dev/null
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --json --db-path /tmp/phage-rv-core-persisted > /tmp/phage-rv-core-persisted.json
python3 -m json.tool /tmp/phage-rv-core-persisted.json >/dev/null
```

Phage server-load example within current caps:

```sh
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-rv-server-load --clients 2 --requests 100 --json > /tmp/phage-rv-server-load.json
python3 -m json.tool /tmp/phage-rv-server-load.json >/dev/null
```

Redis/Valkey command shapes, to be finalized by S1 after binary discovery:

```sh
python3 bench/redis-valkey-comparison.py --target redis --native --clients 2 --requests 100 --payload-size 16 --pipeline 1 --output /tmp/phage-rv-redis-native.json
python3 bench/redis-valkey-comparison.py --target valkey --native --clients 2 --requests 100 --payload-size 16 --pipeline 1 --output /tmp/phage-rv-valkey-native.json
python3 bench/redis-valkey-comparison.py --target redis --mixed --clients 2 --requests 100 --payload-size 16 --pipeline 1 --output /tmp/phage-rv-redis-mixed.json
python3 bench/redis-valkey-comparison.py --target valkey --mixed --clients 2 --requests 100 --payload-size 16 --pipeline 1 --output /tmp/phage-rv-valkey-mixed.json
python3 -m json.tool /tmp/phage-rv-redis-native.json >/dev/null
python3 -m json.tool /tmp/phage-rv-valkey-native.json >/dev/null
python3 -m json.tool /tmp/phage-rv-redis-mixed.json >/dev/null
python3 -m json.tool /tmp/phage-rv-valkey-mixed.json >/dev/null
```

Artifact cleanup checks should include all generated Phage and Redis/Valkey paths named by the run. At minimum:

```sh
git status --short --untracked-files=all
test ! -e /tmp/phage-rv-core-persisted
test ! -e /tmp/phage-rv-core-persisted.wal
test ! -e /tmp/phage-rv-core-persisted.compact.tmp
test ! -e /tmp/phage-rv-server-load
test ! -e /tmp/phage-rv-server-load.wal
test ! -e /tmp/phage-rv-server-load.compact.tmp
```

## Completion criteria

- Gate 1 decomposed this PRD into valid Kanban tickets with benchmark-harness/setup, run/collect evidence, docs/review, final-audit, and continuation cards.
- S1 setup/harness checks are complete, reviewed, and disposable.
- S2 evidence is complete or explicitly blocked/deferred with exact missing-tool/setup status.
- S3 review approved claims and artifact hygiene or created remediation cards.
- Gate 2 produced an evidence-based final gap check against this PRD.
- Gate 3 generated the next PRD and queued the next available work.

## Related documents

- [Server concurrency architecture PRD](2026-05-18-phage-server-concurrency-architecture-prd.md)
- [Server throughput and observability PRD](2026-05-18-phage-server-throughput-observability-prd.md)
- [Benchmark Matrix and Linux io_uring Verification PRD](2026-05-18-phage-benchmark-matrix-linux-verification-prd.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [Server concurrency architecture audit](../design/2026-05-18-server-concurrency-architecture.md)
- [Server throughput baseline evidence](../benchmarks/2026-05-18-server-throughput.md)
- [macOS POSIX-fallback benchmark baseline](../benchmarks/2026-05-18-macos-fallback-baseline.md)
- [Linux io_uring benchmark verification](../benchmarks/2026-05-18-linux-io-uring-verification.md)
