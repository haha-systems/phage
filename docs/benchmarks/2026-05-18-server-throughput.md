# Server throughput baseline evidence — 2026-05-18

Status: S2 curated macOS baseline evidence plus S4 Linux server-load verification for the server throughput and observability PRD.
PRD slices: S2 — establish curated server load baselines; S4 — verify Linux/server-platform status for the load path.

This note records curated load evidence only. Raw JSON, database, WAL, `.compact.tmp`, and log artifacts are local run outputs and are intentionally not committed.

## Scope

The accepted S1 harness commit used for this baseline is:

- `437eb82c2fadd5e24fce44c8edee4e2fd0d41542` — `feat(server): add bounded load smoke harness`

The `server-load` harness starts the local `phage-server`, drives bounded ZeroMQ REQ clients against the current single REP loop, records throughput and request latency percentiles, verifies the server emitted shutdown metrics, and removes generated store artifacts. These S2 rows are measurement-only baseline evidence for the current serialized server runtime before any S3 read/response-path optimization.

## Host and tool metadata

- Collection timestamp: `2026-05-18T18:00:24Z`.
- Git revision: `437eb82c2fadd5e24fce44c8edee4e2fd0d41542`.
- Zig version: `0.15.2`.
- OS/platform: `Darwin ari.local 25.2.0 Darwin Kernel Version 25.2.0: Tue Nov 18 21:08:48 PST 2025; root:xnu-12377.61.12~1/RELEASE_ARM64_T8132 arm64`.
- libzmq version from `pkg-config --modversion libzmq`: `4.3.5`.
- Build mode: `-Doptimize=ReleaseFast`.
- Backend status reported by harness: `macos-posix-fallback`.
- Runtime model reported by harness: `multi-client-serialized-req-rep`.

Important interpretation: every row in this note was collected locally on macOS and exercises Phage's POSIX fallback storage path. These rows are not Linux `io_uring` evidence and must not be relabeled as Linux server performance.

## Commands run

Repository and host metadata:

```sh
git status --short --untracked-files=all
git rev-parse HEAD
zig version
uname -a
pkg-config --modversion libzmq
```

One-client baseline:

```sh
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-server-throughput-s2-38928-c1-db --clients 1 --requests 100 --json > /tmp/phage-server-throughput-s2-38928-c1.json
python3 -m json.tool /tmp/phage-server-throughput-s2-38928-c1.json >/dev/null
```

Two-client baseline:

```sh
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-server-throughput-s2-38928-c2-db --clients 2 --requests 100 --json > /tmp/phage-server-throughput-s2-38928-c2.json
python3 -m json.tool /tmp/phage-server-throughput-s2-38928-c2.json >/dev/null
```

Artifact checks:

```sh
test ! -e /tmp/phage-server-throughput-s2-38928-c1-db
test ! -e /tmp/phage-server-throughput-s2-38928-c1-db.wal
test ! -e /tmp/phage-server-throughput-s2-38928-c1-db.compact.tmp
test ! -e /tmp/phage-server-throughput-s2-38928-c2-db
test ! -e /tmp/phage-server-throughput-s2-38928-c2-db.wal
test ! -e /tmp/phage-server-throughput-s2-38928-c2-db.compact.tmp
```

## Representative macOS POSIX-fallback rows

Both rows use the same bounded request shape: `100` requests per client with the S1 harness's deterministic `PING`, `SET`, `GET`, `DELETE` rotation. Command counts are total commands across all clients.

| Source | Git revision | Clients | Requests/client | Total requests | Request mix | Runtime model | Backend status | Elapsed (ms) | Requests/sec | p50/p95/p99 latency (us) | Errors | Shutdown metrics | Cleanup |
| --- | --- | ---: | ---: | ---: | --- | --- | --- | ---: | ---: | --- | ---: | --- | --- |
| S2 local baseline | `437eb82` | 1 | 100 | 100 | ping 25, set 25, get 25, delete 25 | `multi-client-serialized-req-rep` | `macos-posix-fallback` | 38.95 | 2,567.53 | 215 / 944 / 1,538 | 0 | `shutdown_metrics_log_captured=true` | `clean` |
| S2 local baseline | `437eb82` | 2 | 100 | 200 | ping 50, set 50, get 50, delete 50 | `multi-client-serialized-req-rep` | `macos-posix-fallback` | 33.57 | 5,957.35 | 194 / 860 / 1,065 | 0 | `shutdown_metrics_log_captured=true` | `clean` |

## Interpretation

- The current server runtime remains a serialized ZeroMQ REP loop. The multi-client row is local queueing and REQ/REP harness evidence, not proof of parallel command execution.
- The 1-client and 2-client rows are comparable bounded baselines for the current S1 harness and ReleaseFast server build at commit `437eb82`.
- Both rows report zero request errors, balanced command counts for the deterministic request mix, captured shutdown metrics, and clean store-artifact cleanup.
- These macOS rows are useful for S3 before/after comparison against the same command shape. Linux `io_uring` server status is recorded separately in the S4 section below.

## S4 Linux server-load verification

S4 used an approved OrbStack Linux execution path and a temporary native Linux clone at `/tmp/phage-server-s4-1779129012` rather than the macOS working tree. The run verifies the current server load path on Linux and keeps it separate from the macOS POSIX-fallback rows above.

### Linux host and tool metadata

- Collection timestamp: `2026-05-18T18:43:09Z`.
- Git revision: `833216f74f7287a5b832da933892e75e09de77a6` — `perf(server): reduce response-path overhead`.
- Linux machine: OrbStack `phage-linux`, Ubuntu noble/24.04, arm64.
- OS/platform: `Linux phage-linux 7.0.5-orbstack-00330-ge3df4e19b0a0-dirty #1 SMP PREEMPT Sun May 10 11:47:42 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux`.
- Zig version: `0.15.2`.
- ZeroMQ/`zimq` status: `pkg-config --modversion libzmq` was unavailable with `pkg-config: command not found`, but the pinned Zig `zimq` dependency built and the live server smoke, sustained smoke, and load harness all completed successfully.
- Backend status reported by load harness: `linux-io-uring-intended`.
- Runtime model reported by load harness: `multi-client-serialized-req-rep`.

### Linux commands run

Repository and host metadata:

```sh
orbctl version
orb list
git clone /mnt/mac/Users/xiy/code/phage /tmp/phage-server-s4-1779129012
git -C /tmp/phage-server-s4-1779129012 status --short --untracked-files=all
git -C /tmp/phage-server-s4-1779129012 rev-parse HEAD
uname -a
zig version
pkg-config --modversion libzmq
```

Verification and load commands:

```sh
cd /tmp/phage-server-s4-1779129012
zig build test
timeout 60 zig build server-smoke -- --db-path /tmp/phage-linux-server-smoke-s4-1779129012b
timeout 120 zig build server-sustained-smoke -- --db-path /tmp/phage-linux-server-sustained-s4-1779129012 --clients 2 --requests 100
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-linux-server-load-json-s4-1779129012 --clients 2 --requests 100 --json > /tmp/phage-linux-server-load-s4-1779129012.json
python3 -m json.tool /tmp/phage-linux-server-load-s4-1779129012.json >/dev/null
```

The first smoke attempt was run through the macOS `orb` wrapper with a 600-second host-side timeout and left `/tmp/phage-linux-server-smoke-s4-1779129012` plus its `.wal` until manually removed. Rerunning the same smoke inside Linux with `timeout 60` passed and exited cleanly; the final cleanup check below confirms all generated store paths are absent.

### Linux results

- `zig build test`: passed on Linux; test runner groups included `58 of 58 tests passed`, benchmark tests `14 of 14`, server config tests `9 of 9`, load tests `5 of 5`, and server shutdown-state tests `2 of 2`.
- `server-smoke`: passed; endpoint `tcp://127.0.0.1:32949`, database `/tmp/phage-linux-server-smoke-s4-1779129012b`, shutdown metrics `reads=1 writes=4 deletes=2 read_errors=3 write_errors=0 delete_errors=0` after MVP, missing-key, malformed-command, and invalid-regex request coverage.
- `server-sustained-smoke`: passed; endpoint `tcp://127.0.0.1:45427`, clients `2`, requests/client `100`, total requests `200`, runtime model `multi-client-serialized-req-rep`, `shutdown_metrics_log_captured=true`, shutdown metrics `reads=50 writes=50 deletes=50 read_errors=0 write_errors=0 delete_errors=0`.

Linux load row with validated JSON output:

| Source | Git revision | Clients | Requests/client | Total requests | Request mix | Runtime model | Backend status | Elapsed (ms) | Requests/sec | p50/p95/p99 latency (us) | Errors | Shutdown metrics | Cleanup |
| --- | --- | ---: | ---: | ---: | --- | --- | --- | ---: | ---: | --- | ---: | --- | --- |
| S4 OrbStack Linux load | `833216f` | 2 | 100 | 200 | ping 50, set 50, get 50, delete 50 | `multi-client-serialized-req-rep` | `linux-io-uring-intended` | 16.55 | 12,083.50 | 124.33 / 281.71 / 457.29 | 0 | `shutdown_metrics_log_captured=true` | `clean` |

### Linux interpretation

- This is real Linux server-load evidence for the intended `io_uring` backend selection path: the load harness reported `backend_status=linux-io-uring-intended` on OrbStack Ubuntu arm64 with Zig `0.15.2`.
- The server runtime is still the single ZeroMQ REP loop, so this row remains serialized REQ/REP load evidence rather than proof of parallel command execution.
- The macOS POSIX-fallback rows above remain separate baseline evidence and must not be compared as Linux backend performance claims.

## Artifact hygiene

The raw JSON files were written under `/tmp` for validation with `python3 -m json.tool` and are not committed. The harness reported `cleanup_status=clean`; explicit post-run checks confirmed these generated store paths were absent after the runs:

- `/tmp/phage-server-throughput-s2-38928-c1-db`
- `/tmp/phage-server-throughput-s2-38928-c1-db.wal`
- `/tmp/phage-server-throughput-s2-38928-c1-db.compact.tmp`
- `/tmp/phage-server-throughput-s2-38928-c2-db`
- `/tmp/phage-server-throughput-s2-38928-c2-db.wal`
- `/tmp/phage-server-throughput-s2-38928-c2-db.compact.tmp`
- `/tmp/phage-linux-server-smoke-s4-1779129012`
- `/tmp/phage-linux-server-smoke-s4-1779129012.wal`
- `/tmp/phage-linux-server-smoke-s4-1779129012.compact.tmp`
- `/tmp/phage-linux-server-smoke-s4-1779129012b`
- `/tmp/phage-linux-server-smoke-s4-1779129012b.wal`
- `/tmp/phage-linux-server-smoke-s4-1779129012b.compact.tmp`
- `/tmp/phage-linux-server-sustained-s4-1779129012`
- `/tmp/phage-linux-server-sustained-s4-1779129012.wal`
- `/tmp/phage-linux-server-sustained-s4-1779129012.compact.tmp`
- `/tmp/phage-linux-server-load-s4-1779129012`
- `/tmp/phage-linux-server-load-s4-1779129012.wal`
- `/tmp/phage-linux-server-load-s4-1779129012.compact.tmp`
- `/tmp/phage-linux-server-load-json-s4-1779129012`
- `/tmp/phage-linux-server-load-json-s4-1779129012.wal`
- `/tmp/phage-linux-server-load-json-s4-1779129012.compact.tmp`

The S4 raw JSON file `/tmp/phage-linux-server-load-s4-1779129012.json` and temporary clone/cache path `/tmp/phage-server-s4-1779129012` remained under Linux `/tmp` and are not staged. Repository-root `matrix.json-summary.json` and the untracked PRD/template files existed before this docs slice and remain unrelated and unstaged.

## Related documents

- [Server throughput and observability PRD](../prds/2026-05-18-phage-server-throughput-observability-prd.md)
- [Server build and runtime verification PRD](../prds/2026-05-18-phage-server-build-runtime-prd.md)
- [Compaction benchmark and status evidence](2026-05-18-compaction-performance.md)
- [Linux io_uring benchmark verification](2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [API Reference](../API_REFERENCE.md)
- [Getting Started](../GETTING_STARTED.md)
