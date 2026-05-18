# Phage Redis/Valkey local comparison evidence — 2026-05-18

Status: S2 bounded local macOS evidence for the Redis/Valkey comparison PRD.
PRD slice: S2 — run bounded local comparison and curate evidence.
Raw output directory: `/tmp/phage-rv-20260518T200729Z`. Raw JSON/CSV/logs and the temporary worktree are local `/tmp` artifacts and are intentionally not committed.

This note keeps four measurement categories separate: Phage core/in-process, Phage server-load, Redis/Valkey native benchmark-tool, and Redis/Valkey custom mixed workload. Redis and Valkey are mature reference systems; these small local smoke rows are for measurement discipline and context only, not broad product-level winner claims.

## Scope and interpretation guardrails

- Phage was benchmarked from an isolated clean temporary worktree because `/Users/xiy/code/phage` had unrelated modified/untracked files before this slice. Subject SHA: `7ffbdc8a1e5ed7a6c1af64b35c3a0b2a63f38b83`; temporary worktree: `/tmp/phage-rv-20260518T200729Z/phage-worktree`.
- The local host is macOS and Phage reports `macos-posix-fallback`; none of these rows are Linux `io_uring` evidence.
- The Phage server-load row exercises the current ZeroMQ `multi-client-serialized-req-rep` runtime: multiple clients connect, but one REP loop serializes command execution.
- Phage core/in-process rows are storage-engine fast-path context and are not directly equivalent to Valkey network-server rows.
- Redis rows are unavailable in this run because the local `redis-*` compatibility binaries resolve to Valkey 9.0.4; the setup harness rejected them as wrong binaries.

## Host, tool, and repository metadata

| Field | Value |
| --- | --- |
| Collection timestamp | `2026-05-18T20:07:29Z` discovery; benchmark run `2026-05-18T20:10:06Z`–`2026-05-18T20:10:07Z` |
| Repository status before docs change | dirty main worktree with unrelated `M build.zig`, `M src/server/config.zig`, `M src/server/harness.zig`, `M src/server/load_smoke.zig`, `M src/server/sustained_smoke.zig`, `M src/zserver.zig`, `?? .DS_Store`, `?? AGENTS.md`, `?? docs/prds/2026-05-18-overnight-phage-work-prd.md`, `?? docs/prds/_template.md`, `?? matrix.json-summary.json`, `?? src/server/concurrent_runtime.zig` |
| Pinned Phage subject | clean temp worktree `/tmp/phage-rv-20260518T200729Z/phage-worktree` at `7ffbdc8a1e5ed7a6c1af64b35c3a0b2a63f38b83` |
| macOS / uname | `Darwin ari.local 25.2.0 Darwin Kernel Version 25.2.0: Tue Nov 18 21:08:48 PST 2025; root:xnu-12377.61.12~1/RELEASE_ARM64_T8132 arm64` |
| macOS product version | `26.2` |
| Architecture | `arm64` |
| Zig | `0.15.2` |
| libzmq status | `pkg-config --modversion libzmq` => `4.3.5`; Homebrew prefix `/opt/homebrew/opt/zeromq` |
| Redis server path/version status | `/opt/homebrew/bin/redis-server` -> Valkey server; rejected: `redis server binary identity mismatch for /opt/homebrew/Cellar/valkey/9.0.4/bin/valkey-server: version output was 'Valkey server v=9.0.4 sha=00000000:1 malloc=libc bits=64 build=dd182225677f0e7c'` |
| Redis benchmark/CLI status | `/opt/homebrew/bin/redis-benchmark` => `valkey-benchmark 9.0.4`; `/opt/homebrew/bin/redis-cli` => `valkey-cli 9.0.4`; not used as Redis evidence |
| Valkey server | `/opt/homebrew/Cellar/valkey/9.0.4/bin/valkey-server`; `Valkey server v=9.0.4 sha=00000000:1 malloc=libc bits=64 build=dd182225677f0e7c` |
| Valkey benchmark | `/opt/homebrew/Cellar/valkey/9.0.4/bin/valkey-benchmark`; `valkey-benchmark 9.0.4` |
| Valkey CLI | `/opt/homebrew/Cellar/valkey/9.0.4/bin/valkey-cli`; `valkey-cli 9.0.4` |

Disposable setup checks:

| Target | Status | Temp process/persistence | Cleanup | Source command |
| --- | --- | --- | --- | --- |
| Redis | unavailable / fail-closed | not started; server role resolved to Valkey, not Redis | JSON diagnostic valid | `python3 bench/redis_valkey_comparison.py --setup-only --target redis --output /tmp/phage-rv-20260518T200729Z/setup-redis-clean-worktree.json` |
| Valkey | ok | `--bind 127.0.0.1 --port 55818 --dir /private/tmp/phage-redis-valkey-comparison-5s7s2h8x --save "" --appendonly no --dbfilename dump.rdb --daemonize no --protected-mode yes` | `cleanup_ok=true`, no leftovers | `python3 bench/redis_valkey_comparison.py --setup-only --target valkey --output /tmp/phage-rv-20260518T200729Z/setup-valkey-clean-worktree.json` |

## Category 1 — Phage core/in-process rows (`category=phage-core-in-process`)

These rows come from the native in-process benchmark executable and do not include network protocol overhead.

| Category | Mode | Backend/runtime | Payload size | Client count | Request/operation count | Batch/pipeline | Command mix / read API | Durability | Throughput | Latency fields | Errors/status | Cleanup | Source command |
| --- | --- | --- | ---: | --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| `phage-core-in-process` | `memory` | `backend_status=macos-posix-fallback`; in-process | 16 B | n/a | 1000 writes + 1000 reads | batch size 16 | standard put/get; read API `getInto` | memory HashMap baseline, no WAL/fsync | write 7,633,587.79 ops/s; read 24,390,243.90 ops/s; total 11,627,906.98 ops/s | write p50/p95/p99 0.06 / 0.31 / 0.75 us; read p50/p95/p99 0.0 / 0.0 / 1.0 us | command exit 0; JSON valid | no DB/WAL artifacts expected | `zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json` |
| `phage-core-in-process` | `persisted` | `backend_status=macos-posix-fallback`; in-process | 16 B | n/a | 1000 writes + 1000 reads | batch size 16 | standard put/get; read API `getInto` | persisted local `/tmp` store + WAL during run | write 1,237,623.76 ops/s; read 1,177,856.30 ops/s; total 1,207,000.60 ops/s | write p50/p95/p99 0.69 / 1.06 / 3.19 us; read p50/p95/p99 1.0 / 1.0 / 1.0 us | command exit 0; JSON valid | persisted `/tmp` store, `.wal`, `.compact.tmp` absent after cleanup | `zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --read-api get-into --json --db-path /tmp/phage-rv-20260518T200729Z/phage-core-persisted-store` |

## Category 2 — Phage server-load rows (`category=phage-server-load`)

This row is bounded by the current server-load caps: clients `2 <= 32`, total requests `200 <= 2000`.

| Category | Backend/runtime | Payload size | Clients | Requests/client | Total requests | Batch/pipeline | Command mix | Durability | Throughput | Latency fields | Errors/status | Cleanup | Source command |
| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | ---: | --- | ---: | --- | --- |
| `phage-server-load` | `multi-client-serialized-req-rep`; `backend_status=macos-posix-fallback` | harness text values `value-{client}-{request}` (not a fixed payload-size option) | 2 | 100 | 200 | ZeroMQ REQ/REP, one outstanding request per client | ping 50, set 50, get 50, delete 50 | persisted `/tmp` Phage store during run; cleaned after | 7,167.43 req/s | p50/p95/p99 154.0 / 707.0 / 850.0 us | 0 | `clean`; shutdown metrics captured `true` | `zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-rv-20260518T200729Z/phage-server-load-store --clients 2 --requests 100 --json` |

## Category 3 — Redis/Valkey native benchmark-tool rows (`category=redis-native-benchmark` / `category=valkey-native-benchmark`)

Native benchmark-tool rows use Valkey's own benchmark workload and protocol path. They are valuable reference evidence, but their command mix/runtime are not equivalent to Phage server-load.

| Category | Target/test | Server/binary status | Payload size | Clients | Request count | Pipeline | Persistence/durability | Command mix | Throughput | Latency fields | Errors/status | Cleanup | Source command |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: | --- | --- | --- | --- |
| `redis-native-benchmark` | n/a | unavailable: `redis-server` resolved to Valkey and was rejected as wrong binary | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | setup JSON valid; no Redis result fabricated | n/a | `python3 bench/redis_valkey_comparison.py --setup-only --target redis --output /tmp/phage-rv-20260518T200729Z/setup-redis-clean-worktree.json` |
| `valkey-native-benchmark` | `PING_INLINE` | server `Valkey server v=9.0.4 sha=00000000:1 malloc=libc bits=64 build=dd182225677f0e7c`; benchmark `valkey-benchmark 9.0.4` | 16 B | 2 | 200 per native subtest | 1 | disposable temp dir, `save ""`, `appendonly no`, no durable service | native `-t ping,set,get` emits `PING_INLINE` | 40,000.00 req/s | avg 0.046 ms; min 0.032 ms; p50/p95/p99 0.047 / 0.055 / 0.063 ms; max 0.167 ms | command exit 0 | `cleanup_ok=true`; server terminated without SIGKILL | `/opt/homebrew/bin/valkey-benchmark -h 127.0.0.1 -p 55784 -n 200 -c 2 -P 1 -d 16 -t ping,set,get --csv` |
| `valkey-native-benchmark` | `PING_MBULK` | server `Valkey server v=9.0.4 sha=00000000:1 malloc=libc bits=64 build=dd182225677f0e7c`; benchmark `valkey-benchmark 9.0.4` | 16 B | 2 | 200 per native subtest | 1 | disposable temp dir, `save ""`, `appendonly no`, no durable service | native `-t ping,set,get` emits `PING_MBULK` | 33,333.33 req/s | avg 0.047 ms; min 0.024 ms; p50/p95/p99 0.047 / 0.063 / 0.079 ms; max 0.103 ms | command exit 0 | `cleanup_ok=true`; server terminated without SIGKILL | `/opt/homebrew/bin/valkey-benchmark -h 127.0.0.1 -p 55784 -n 200 -c 2 -P 1 -d 16 -t ping,set,get --csv` |
| `valkey-native-benchmark` | `SET` | server `Valkey server v=9.0.4 sha=00000000:1 malloc=libc bits=64 build=dd182225677f0e7c`; benchmark `valkey-benchmark 9.0.4` | 16 B | 2 | 200 per native subtest | 1 | disposable temp dir, `save ""`, `appendonly no`, no durable service | native `-t ping,set,get` emits `SET` | 33,333.33 req/s | avg 0.052 ms; min 0.032 ms; p50/p95/p99 0.047 / 0.063 / 0.087 ms; max 0.575 ms | command exit 0 | `cleanup_ok=true`; server terminated without SIGKILL | `/opt/homebrew/bin/valkey-benchmark -h 127.0.0.1 -p 55784 -n 200 -c 2 -P 1 -d 16 -t ping,set,get --csv` |
| `valkey-native-benchmark` | `GET` | server `Valkey server v=9.0.4 sha=00000000:1 malloc=libc bits=64 build=dd182225677f0e7c`; benchmark `valkey-benchmark 9.0.4` | 16 B | 2 | 200 per native subtest | 1 | disposable temp dir, `save ""`, `appendonly no`, no durable service | native `-t ping,set,get` emits `GET` | 40,000.00 req/s | avg 0.038 ms; min 0.024 ms; p50/p95/p99 0.039 / 0.055 / 0.087 ms; max 0.103 ms | command exit 0 | `cleanup_ok=true`; server terminated without SIGKILL | `/opt/homebrew/bin/valkey-benchmark -h 127.0.0.1 -p 55784 -n 200 -c 2 -P 1 -d 16 -t ping,set,get --csv` |


## Category 4 — Redis/Valkey custom mixed workload (`category=redis-custom-mixed` / `category=valkey-custom-mixed`)

The custom Valkey workload uses the same bounded count and 25% `PING`, 25% `SET`, 25% `GET`, 25% `DEL` mix as the Phage server-load row, with a simple RESP socket driver and 16-byte SET values. It remains a protocol/runtime comparison, not an exact implementation-equivalence claim.

| Category | Backend/runtime | Payload size | Clients | Requests/client | Total requests | Batch/pipeline | Persistence/durability | Command mix | Throughput | Latency fields | Errors/status | Cleanup | Source command |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- | ---: | --- | ---: | --- | --- |
| `redis-custom-mixed` | unavailable | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | setup JSON valid; no Redis result fabricated | n/a | `python3 bench/redis_valkey_comparison.py --setup-only --target redis --output /tmp/phage-rv-20260518T200729Z/setup-redis-clean-worktree.json` |
| `valkey-custom-mixed` | Valkey RESP server, disposable local process | 16 B | 2 | 100 | 200 | pipeline 1; none, sequential request/response per client stream | temp dir `/private/tmp/phage-redis-valkey-comparison-run-2q2fe_rb`; `save ""`; `appendonly no` | ping 50, set 50, get 50, delete 50 | 16,691.12 req/s | p50/p95/p99 47.04 / 85.29 / 101.38 us | 0 | `cleanup_ok=true`; terminated without SIGKILL `true` | `python3 /tmp/phage-rv-run-benchmarks.py` (RESP socket custom mixed workload) |

## Commands and raw evidence

Raw files kept under `/tmp/phage-rv-20260518T200729Z` during curation:

- `discovery.txt`
- `setup-redis-clean-worktree.json`
- `setup-valkey-clean-worktree.json`
- `phage-core-memory.json`
- `phage-core-persisted.json`
- `phage-server-load.json`
- `valkey-native.csv`
- `valkey-custom-mixed.json`
- `run-manifest.json`

The temporary Valkey run command was:

```sh
/opt/homebrew/bin/valkey-server --bind 127.0.0.1 --port 55784 --dir /private/tmp/phage-redis-valkey-comparison-run-2q2fe_rb --save  --appendonly no --dbfilename dump.rdb --daemonize no --protected-mode yes
```

The custom mixed workload driver was a temporary Python RESP-socket command sequence under `/tmp`, not a committed harness extension. It sent exactly 200 commands: 50 `PING`, 50 `SET`, 50 `GET`, and 50 `DEL`, with one request/response outstanding at a time.

## Artifact hygiene

- Phage persisted core store path: `/tmp/phage-rv-20260518T200729Z/phage-core-persisted-store`; post-run cleanup removed the store, `.wal`, and `.compact.tmp` paths.
- Phage server-load store path: `/tmp/phage-rv-20260518T200729Z/phage-server-load-store`; the harness reported `cleanup_status=clean`, and the store, `.wal`, and `.compact.tmp` paths were absent after the run.
- Valkey setup temp dir `/private/tmp/phage-redis-valkey-comparison-5s7s2h8x` was removed by the setup harness with no leftovers.
- Valkey benchmark/custom temp dir `/private/tmp/phage-redis-valkey-comparison-run-2q2fe_rb` was removed by the run script with `cleanup_ok=true`.
- Redis was not started because setup failed closed before launching a process.
- Raw outputs/logs remain under `/tmp` and are not staged. The isolated worktree remains at `/tmp/phage-rv-20260518T200729Z/phage-worktree` as a `/tmp`-only pinned-subject artifact for reviewer inspection; validation pretty-print copies are `/tmp/phage-rv-*.pretty.json` and are also unstaged. The only intended staged file for this S2 slice is this Markdown evidence note.

## Verification log

This section was finalized after writing the note.

| Command | Exit code | Notes |
| --- | ---: | --- |
| `git status --short --untracked-files=all` | 0 | showed this new note plus pre-existing unrelated dirty paths: `M build.zig`, `M src/server/config.zig`, `M src/server/harness.zig`, `M src/server/load_smoke.zig`, `M src/server/sustained_smoke.zig`, `M src/zserver.zig`, `?? .DS_Store`, `?? AGENTS.md`, `?? docs/prds/2026-05-18-overnight-phage-work-prd.md`, `?? docs/prds/_template.md`, `?? matrix.json-summary.json`, `?? src/server/concurrent_runtime.zig` |
| `git diff --check` | 0 | no whitespace errors in tracked diffs |
| `python3 -m json.tool` for setup/core/server/custom JSON files | 0 | setup Redis/Valkey clean-worktree JSON, Phage core JSON, Phage server-load JSON, Valkey custom mixed JSON, and run manifest validated |
| `env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest bench/test_redis_valkey_comparison.py` | 0 | 8 tests passed in the clean temp worktree |
| `zig build test` | 0 | run in the clean temp worktree for the pinned subject; all Zig/Python test steps passed, including 58 library tests, 14 benchmark tests, 14 server config tests, 7 server-load tests, and harness setup unit tests |

## Conservative reading

These rows are small single-run local smoke measurements. They should be used to check measurement surfaces, metadata coverage, and rough local context only. They should not be used to claim Phage generally beats, matches, or trails Redis/Valkey in production. A fuller comparison would need real Redis binaries, repeated measurements, pinned CPU/power conditions, Linux `io_uring` rows, richer protocol compatibility, and carefully matched durability/runtime settings.

## Related documents

- [Redis/Valkey comparison benchmark PRD](../prds/2026-05-18-phage-redis-valkey-comparison-benchmark-prd.md)
- [Server throughput baseline evidence](2026-05-18-server-throughput.md)
- [macOS POSIX-fallback benchmark baseline](2026-05-18-macos-fallback-baseline.md)
- [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
