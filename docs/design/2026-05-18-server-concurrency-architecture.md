# Server concurrency architecture audit — 2026-05-18

Status: S1 audit for [Phage server concurrency architecture PRD](../prds/2026-05-18-phage-server-concurrency-architecture-prd.md).

## Decision

Concurrent command execution is not approved for implementation yet.

Phage can proceed with the S2 handler extraction, and it can keep designing a bounded opt-in server mode, but S3 must not run multiple worker threads concurrently through one shared `phage.Phage` instance until the Linux backend and index-iteration blockers below are fixed or deliberately serialized behind one store-executor lane.

The practical go/no-go is:

- Go for S2: extract parse/execute/response handling from the current REP loop while preserving byte-for-byte protocol behavior.
- No-go for parallel shared-store workers in S3 as-is: `LinuxIoUringBackend` owns one mutable `linux.IoUring` with no ring mutex, while public `get` allows concurrent readers to call the backend at the same time.
- No-go for concurrent `KEYS` with writes/deletes as-is: `findKeys`, `printKeys`, and `IndexManager.count` iterate shard maps without consistently taking shard locks.
- Conditional future shape: a bounded ROUTER-style or equivalent dispatcher may be implemented after S2, but it must keep ZeroMQ socket ownership thread-local, copy request bytes before worker handoff, bound workers/queues, and either fix backend/index concurrency first or serialize all store access through one store executor and report that runtime truthfully as not parallel store execution.

## Current serialized runtime

`src/zserver.zig` currently owns one process allocator, one `phage.Phage` store, one ZeroMQ context, and one REP socket. The server binds the REP socket, then loops while `server_runtime.processShouldContinue()` is true: receive one message, parse `buf.slice()`, execute one command against the shared store, send one reply, and only then receive the next request (`src/zserver.zig:16-141`). That is correctly documented by the load evidence as `runtime_model=multi-client-serialized-req-rep`.

The server-throughput note records this exact interpretation: multi-client load accepts multiple clients but proves queueing through the current single REP loop, not parallel command execution (`docs/benchmarks/2026-05-18-server-throughput.md:14`, `:24-27`, `:75-80`, `:137-141`).

## Source-level audit

| Boundary | Evidence | S1 conclusion |
| --- | --- | --- |
| Store mutation serialization | `Phage` has `mutation_mutex` documented to serialize main-file/WAL/index mutations with inline compaction (`src/root.zig:52-59`). `put`, `putBatch`, and `delete` lock it for their mutation paths (`src/root.zig:190-238`, `:243-304`, `:403-423`). | Writes/deletes are serialized at the store API boundary. This is necessary but not sufficient for a concurrent server because reads can still call the shared backend concurrently. |
| Public reads vs compaction | `Phage` has `read_compaction_lock` documented to keep reads on one stable file/index generation (`src/root.zig:56-59`). `get` and `getInto` take the shared lock (`src/root.zig:317-348`); compaction takes the exclusive lock before rewriting and swapping files (`src/root.zig:680-799`). | Reads and compaction generation changes are coordinated. Multiple reads may run at the same time, which exposes the backend thread-safety blocker below. |
| Index point operations | `IndexManager` shards have a mutex (`src/index.zig:34-45`), and `put`, `putBatch`, `get`, and `delete` lock the relevant shard(s) (`src/index.zig:126-186`). | Point lookups and updates have shard-level protection. |
| Index iteration and counting | `findKeys` iterates `self.index.shards` and each `shard.map.keyIterator()` without locking (`src/root.zig:470-512`). `printKeys` also iterates maps without locks and calls `self.get` while iterating (`src/root.zig:515-568`). `IndexManager.count` sums `shard.map.count()` without locking (`src/index.zig:105-115`). | `KEYS` and internal count-dependent code are not safe to run concurrently with writes/deletes. S3 must fix iteration/count locking or exclude/serialize `KEYS` in any concurrent runtime. |
| Backend completion queue ownership | macOS uses `PosixBackend`, which is stateless wrappers around positioned `pread`/`pwrite` and `wait` is a no-op (`src/io/backend.zig:26-64`). Linux uses one `LinuxIoUringBackend` with one `linux.IoUring` and `pending_ops` atomic (`src/io/backend.zig:194-229`). Ring submission/completion helpers mutate SQ/CQ state without any mutex (`src/io/backend.zig:66-191`). | POSIX fallback is closer to shareable, but the Linux intended path is not safe for concurrent callers into one backend. The atomic pending counter does not make the ring itself thread-safe. This is the primary blocker for parallel shared-store workers. |
| WAL and file-size state | Store writes use atomic file-size counters for offsets and WAL offsets (`src/root.zig:203-214`, `:413-416`), and WAL clear truncates/fsyncs then resets `wal_file_size` (`src/io/wal.zig:163-172`). Those paths are under `mutation_mutex` when called from public mutations. | WAL offset publication is protected for public writes/deletes. It must stay under the store mutation lock if S3 changes execution topology. |
| Compaction | `checkAndScheduleCompaction` uses an atomic in-progress flag and calls `performCompaction` inline (`src/root.zig:656-676`). Compaction takes the exclusive read/compaction lock, copies reachable entries, atomically swaps files, then publishes updated offsets (`src/root.zig:680-799`). | Compaction is not a server-concurrency blocker if all public reads keep taking the shared lock and all public mutations keep taking the mutation lock. The cost is paid by the mutating worker that triggers it, so S3 must account for head-of-line blocking. |
| Metrics | Runtime counters and latency totals are `std.atomic.Value(u64)` and updates use atomic fetch-add/load (`src/metrics/metrics.zig:19-95`). | Metrics are safe for concurrent increments and final snapshots, subject to final snapshot being taken after worker shutdown/drain. |
| Protocol request payload ownership | `parseCommandSlice` tokenizes the inbound request slice and command payload fields point into that slice (`src/protocol/protocol.zig:711-776`). SET/GET/DELETE/KEYS request structs store those borrowed slices (`src/protocol/protocol.zig:323-374`, `:380-427`, `:433-481`, `:525-579`). `zserver` currently executes before `buf.deinit()` (`src/zserver.zig:66-105`). | Safe in the serialized loop. A worker handoff cannot enqueue a parsed `Command` that borrows a ZeroMQ message buffer unless the message lifetime is extended; easiest safe rule is copy raw request bytes into worker-owned storage and parse inside the worker. |
| Protocol response payload ownership | `GET` returns an allocated value from `store.get` (`src/root.zig:317-333`, `src/protocol/protocol.zig:199-206`), `KEYS` returns an owned slice when matches exist (`src/root.zig:491-512`, `src/protocol/protocol.zig:217-224`), and static/borrowed responses are exposed through `Result.borrowedPayloadSlice` (`src/protocol/protocol.zig:270-305`). `zserver` frees GET/KEYS payloads after `sendSlice`/`sendConstSlice` returns (`src/zserver.zig:8-14`, `:127-133`). | Safe only if the send call has consumed or copied the response before freeing. S3 must not queue pointers to stack/request/result memory for async send; response bytes must stay owned until the owning ZeroMQ send completes. Recent work already showed `sendSlice` is the safe path for borrowed/dynamic server responses. |
| ZeroMQ socket ownership | Current server creates one REP socket and uses it on one thread (`src/zserver.zig:53-64`, `:66-133`). The smokes/load harnesses create per-client REQ sockets, often per client thread (`src/server/sustained_smoke.zig:175-186`, `src/server/smoke.zig:189-198`). | S3 must not share a socket across threads. A future runtime should use a ROUTER (or equivalent frontend) owned by one I/O thread and thread-local worker sockets, or another topology with one socket owner per thread. |
| Shutdown state | Process shutdown is an atomic bool updated by SIGINT/SIGTERM handlers (`src/server/runtime.zig:3-49`). The current loop checks it between blocking receives and logs metrics after loop exit (`src/zserver.zig:66-73`, `:136-141`). | The atomic flag is a good shared shutdown primitive, but a concurrent runtime needs explicit socket wakeup/close, worker queue stop, joins, and final metrics after no worker can mutate the store. |
| Load harness semantics | `server-load` bounds clients to 32 and total requests to 2,000, reports `runtime_model`, `backend_status`, command/error counts, latency percentiles, shutdown metrics capture, and cleanup status (`src/server/load_smoke.zig:5-8`, `:50-63`, `:108-187`). Sustained smoke explicitly says multiple connections are accepted but one REP loop serializes command execution (`src/server/sustained_smoke.zig:142-149`). | S3/S4 must add new runtime labels rather than reusing the serialized label for concurrent claims. Evidence must continue to separate macOS POSIX fallback from Linux io_uring. |

## Minimal safe future runtime shape

When the blockers are addressed, the minimal S3 shape should be:

1. Default remains serialized REP with no flag changes.
2. Add explicit opt-in config, for example `--runtime serialized|concurrent --workers N`, with default `serialized`, `workers` rejected at 0, and a small documented cap.
3. Frontend thread owns the ROUTER or equivalent external socket. Worker threads own only their own inproc/thread-local sockets or queue endpoints.
4. Request bytes are copied before crossing thread boundaries, then parsed inside the worker.
5. Response bytes are worker-owned until the frontend or owning socket has completed the send.
6. Store access must choose one of two truthful modes:
   - Parallel store mode, only after Linux backend ring access and KEYS/index iteration are made thread-safe and verified; writes still serialize through `mutation_mutex`, reads may share `read_compaction_lock`, and compaction remains exclusive against public reads.
   - Concurrent network / serialized store-executor mode, where workers can handle network scheduling but all store operations run on one executor. This is safe as an intermediate architecture but must not be benchmarked or documented as parallel command execution.
7. Shutdown closes or wakes sockets/queues, stops accepting new work, drains or cancels bounded queued work, joins workers, and then takes the final metrics snapshot.

## What S2 must preserve

S2 should extract command handling without changing runtime semantics. It must preserve:

- The current parse errors and response strings from `src/zserver.zig:79-133`.
- The current request-borrowing rule: parsed commands are valid only while the request bytes remain alive.
- The current response ownership/freeing rule for GET/KEYS vs static payloads.
- The current serialized REP server label and smoke/load behavior.
- The ability for S3 to use the same handler from either serialized or future worker code.

S2 should be a good place to make request/response ownership explicit in types before S3 introduces queues.

## What S3 must preserve or fix

If S3 attempts a concurrent mode, it must first preserve or fix these constraints:

- Preserve default serialized mode and label it `multi-client-serialized-req-rep`.
- Preserve socket thread ownership; do not call one ZeroMQ socket from multiple threads.
- Preserve store mutation serialization, read/compaction generation locking, WAL clear semantics, compaction temp-file cleanup, and final metrics logging.
- Fix or serialize Linux backend access before multiple threads can call `store.get`, `store.put`, `store.putBatch`, `store.delete`, or `store.findKeys` on the same store.
- Fix `KEYS`/index iteration and `IndexManager.count` locking before allowing `KEYS` concurrently with mutation.
- Use truthful runtime labels such as `bounded-router-serialized-store` for an intermediate executor mode or `bounded-router-shared-store` only if shared-store blockers are actually fixed and verified.
- Keep `server-smoke`, `server-sustained-smoke`, and `server-load` bounded and artifact-clean.

## Remaining risks

- Shared allocator behavior under server worker threads is not documented in the audited server code. Store operations allocate through `store.allocator` for GET/KEYS/BENCHMARK paths (`src/root.zig:330-332`, `src/protocol/protocol.zig:603-632`), so S3 must either use a documented thread-safe allocator configuration or isolate worker/response allocations.
- `BENCHMARK` performs large batches and many allocations against the live store (`src/protocol/protocol.zig:590-645`). In a concurrent runtime it should probably be serialized or disabled from concurrent evidence runs until separately audited.
- Compaction remains inline on the triggering mutation path. That is safe with the existing locks but will cause head-of-line blocking and must be visible in latency evidence.
- The current process shutdown flag does not by itself unblock every possible concurrent socket/queue wait.

## S1 verification choice

This slice is docs-only. No focused safety test was added because the blockers are source-level ownership issues visible in the audited code: the Linux backend exposes one mutable ring without a backend lock, and the KEYS/index iteration paths lack shard locking. The required verification for this card is therefore repository hygiene plus `git diff --check` and `zig build test` to confirm the audited codebase remains green.

## Related documents

- [Server throughput baseline evidence](../benchmarks/2026-05-18-server-throughput.md)
- [Linux io_uring benchmark verification](../benchmarks/2026-05-18-linux-io-uring-verification.md)
- [MVP Roadmap](../MVP_ROADMAP.md)
- [API Reference](../API_REFERENCE.md)
- [Getting Started](../GETTING_STARTED.md)
