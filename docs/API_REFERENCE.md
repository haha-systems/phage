# Phage API Reference

## Current build and server status

Phage currently builds the core library, native benchmark runner, and supported ZeroMQ server workflow through `build.zig`:

```sh
zig build
zig build test
zig build phage-server
zig build run-server -- --help
zig build server-smoke -- --db-path /tmp/phage-server-smoke
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-server-load --clients 2 --requests 100 --json > /tmp/phage-server-load.json
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into
```

The live server smoke starts the built `phage-server` executable on an available localhost port, uses the supplied disposable `/tmp/...` database path, verifies the documented MVP command set over ZeroMQ, terminates the server, and removes the generated database/WAL files. Server build/run/smoke/load steps require the pinned Zig 0.15-compatible `zimq` package from `build.zig.zon` and a working ZeroMQ/libzmq environment; use `zig build --fetch` when dependencies need to be fetched before offline builds. These repository-local workflows do not require the external Demon client.

The sustained server smoke starts the same built executable, opens multiple ZeroMQ REQ client connections, sends bounded repeated checked commands from each client, terminates the server, verifies the shutdown metrics log line, and removes the generated database/WAL files. The accepted `server-load` step extends that workflow into bounded throughput/latency measurement with human or JSON output. The verified runtime model is multi-client serialized REQ/REP handling: multiple clients can connect and issue request/reply traffic, but `src/zserver.zig` runs a single REP receive/execute/send loop, so commands are processed one at a time and these checks do not claim parallel command execution. Curated macOS and Linux server-load evidence is recorded in [server throughput baseline evidence](benchmarks/2026-05-18-server-throughput.md) instead of committed raw JSON artifacts.

## Core store API

The core Zig store type is `Phage` in `src/root.zig`.

| Method | Ownership and behavior |
|--------|------------------------|
| `put(key, value)` | Stores the key/value pair, writes the data/WAL records, updates the index, and records write metrics. |
| `putBatch(pairs)` | Stores multiple key/value pairs with coalesced data/WAL writes and batched shard index updates. Metrics count one write per pair. |
| `get(key)` | Returns an allocator-owned copy of the value. The caller must free the returned slice with the store allocator. Existing allocation-owning behavior is preserved. |
| `getInto(key, buffer)` | Reads the value into caller-provided storage and returns the populated subslice. The returned slice points into `buffer`; no value allocation is performed. Returns `error.InsufficientBuffer` when `buffer.len` is smaller than the stored value, `error.KeyNotFound` for missing keys, and `error.KeyMismatch` if the indexed key does not match the bytes read from storage. |
| `delete(key)` | Removes the key from the index, records a delete WAL entry, and records delete metrics. |
| `findKeys(pattern)` | Returns keys matching the regex-style pattern or `null` when none match. |

`getInto` is intended for read paths that can reuse buffers across calls, such as benchmarks or services that already own request/response storage. Use `get` when caller-owned allocation is more convenient.

### Metrics snapshot

Core storage embeds a metrics accumulator at `store.metrics`. Call `store.metrics.snapshot()` to read counters without mutating them.

Snapshot fields include:

- `reads`, `writes`, `deletes`
- `read_errors`, `write_errors`, `delete_errors`
- `total_read_latency_ns`, `total_write_latency_ns`, `total_delete_latency_ns`

The metrics are in-process counters for local observation and server shutdown logging; they are not a network API or persistent telemetry format.

## Native benchmark CLI

Use the native benchmark build step for reproducible local performance checks:

```sh
zig build -Doptimize=ReleaseFast benchmark -- [OPS] [OPTIONS]
```

Common options:

| Option | Meaning |
|--------|---------|
| positional `OPS` | Number of write/read operations; default is `10000`. |
| `--mode persisted|memory` | `persisted` uses Phage storage; `memory` uses a HashMap baseline without filesystem or WAL I/O. Default is `persisted`. |
| `--value-size BYTES` | Value payload size; default is `16`. |
| `--batch-size N` | Number of writes to group before waiting; default is `1`. |
| `--read-api get|get-into` | Selects allocating `get` or caller-buffer `getInto` for reads. Default is `get`. |
| `--buffered-reads` | Alias for `--read-api get-into`. |
| `--db-path PATH` | Database path for persisted mode; default is `phage_benchmark_store`. Prefer explicit `/tmp/...` paths for smoke docs. |
| `--reuse` | Reuse an existing persisted database instead of deleting it first. |
| `--json` | Emit machine-readable JSON instead of human text. |

Portable examples:

```sh
# Artifact-free macOS/Linux smoke
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16

# Persisted macOS/Linux smoke; macOS uses POSIX fallback, Linux targets io_uring when selected by backend logic
zig build -Doptimize=ReleaseFast benchmark -- 1000 --value-size 16 --batch-size 16 --db-path /tmp/phage-api-bench

# JSON output for automation and caller-buffer read path
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json
```

JSON output includes workload and measurement fields such as mode, operation count, value size, batch size, read API, throughput, and p50/p95/p99 latencies.

## Server configuration and run command implemented in `src/zserver.zig`

```sh
phage-server [OPTIONS]
```

Use the `run-server` build step to start the server from the repository. Pass an explicit disposable database path for examples and local smoke runs so generated store/WAL files stay out of the repo:

```sh
# Press Ctrl-C to stop the server after testing.
zig build run-server -- --db-path /tmp/phage-api-server --port 5555
```

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --port PORT` | Set ZeroMQ REP server port | `5555` |
| `-d, --db-path PATH` | Set database file path | `phage_store` |
| `-l, --log-level LEVEL` | Requested log level (`debug`, `info`, `warn`, `err`) | `info` |
| `-h, --help` | Show help message | - |

The log-level flag is currently reported at startup; it does not dynamically reconfigure Zig's compile-time log filtering.

Server source includes SIGINT/SIGTERM shutdown-state handling and key/value-style lifecycle logs. Live server behavior is verified by explicit smoke/load steps rather than by the default `zig build test` or native `benchmark` workflow. Use `server-smoke` for MVP command coverage, `server-sustained-smoke` for repeated multi-client serialized REQ/REP coverage, and `server-load` for bounded throughput/latency measurement. The protocol `BENCHMARK` command is a server command that mutates the active store; it is not the same as the native benchmark build step or the `server-load` harness.

### Verified runtime/client model

- Transport: ZeroMQ REP server in `src/zserver.zig` with REQ clients.
- Client model verified by smoke: multiple REQ client sockets can connect to the server and complete repeated request/reply commands.
- Execution model: serialized single-server-loop handling. The server receives one message, executes one command against the store, sends one reply, then receives the next message.
- Response path status: common constant/borrowed responses now avoid avoidable allocation in the server send path; protocol responses are unchanged.
- Not claimed: parallel command execution, concurrent store access inside the server process, throughput scaling with client count, or Linux performance from macOS POSIX-fallback rows.
- Shutdown behavior: the sustained smoke sends SIGTERM after the checked requests finish and asserts that stderr includes `server lifecycle event=shutdown` with read/write/delete and error counters.

## Server load harness

Use the repository-local `server-load` build step for bounded live server throughput and latency checks:

```sh
zig build -Doptimize=ReleaseFast server-load -- --db-path /tmp/phage-api-server-load --clients 2 --requests 100 --json > /tmp/phage-api-server-load.json
python3 -m json.tool /tmp/phage-api-server-load.json >/dev/null
```

The harness starts the built `phage-server` on an available localhost port, drives deterministic `PING`/`SET`/`GET`/`DELETE` request mixes from one or more REQ clients, captures shutdown metrics, reports `runtime_model=multi-client-serialized-req-rep`, reports backend/platform status, and removes generated `/tmp` store/WAL artifacts. Treat macOS output as POSIX-fallback local evidence; Linux `io_uring` server status must come from a Linux run. See [server throughput baseline evidence](benchmarks/2026-05-18-server-throughput.md) for curated rows and artifact hygiene.

## Wire protocol

Phage's server protocol is a simple whitespace-delimited text protocol intended for ZeroMQ REQ/REP clients:

```text
COMMAND [arguments...]
```

Command parsing is case-insensitive. Newlines and surrounding whitespace are ignored. Values are single tokens; quoted strings and values containing spaces are not supported by the parser.

## Commands

### SET

```text
SET key value
```

Stores a non-empty key and non-empty single-token value.

Response:
- `OK` on success
- `ERR Missing key`, `ERR Missing value`, `ERR Key cannot be empty`, or `ERR Command execution failed` on error

### GET

```text
GET key
```

Retrieves a value by key.

Response:
- The stored value on success
- `ERR Missing key` for malformed input
- `ERR Command execution failed` when the key is not found or storage fails

### DELETE / DEL

```text
DELETE key
DEL key
```

Deletes a key. The `DEL` alias is accepted by the protocol parser.

Response:
- `OK` on command success
- `ERR Missing key` for malformed input
- `ERR Command execution failed` on storage errors

### KEYS

```text
KEYS pattern
```

Lists keys matching the given pattern. `*` matches all keys; other patterns are regular expressions evaluated by the store's matcher, so prefix-style examples should use regex syntax such as `user:.*`.

Response:
- Matching keys separated by newlines
- `(empty)` when no keys match
- `ERR Missing pattern`, `ERR Pattern cannot be empty`, or `ERR Invalid pattern for KEYS command` on error

Examples:

```text
KEYS *
KEYS user:.*
KEYS config:.*
```

### PING

```text
PING
```

Response:
- `PONG`

### BENCHMARK

```text
BENCHMARK operations
```

Runs the protocol/server benchmark path against the currently open store. This command does not delegate to the native `src/benchmark.zig` runner; it is a separate server command and writes benchmark keys into the active store. Use the native benchmark step for reproducible local benchmarking.

Limits:
- `operations` must be an integer from `1` through `1_000_000`.

Response:
- Benchmark timing summary on success
- `ERR Missing benchmark operation count` or `ERR Unknown command or invalid syntax` for malformed input

Native benchmark example:

```sh
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into
```

## Error response format

Server errors are plain text and begin with `ERR`:

```text
ERR description
```

Common parser/server errors:

| Error | Meaning |
|-------|---------|
| `ERR Unknown command or invalid syntax` | Unknown command or malformed argument count |
| `ERR Missing key` | `SET`, `GET`, or `DELETE` missing a key |
| `ERR Missing value` | `SET` missing a value |
| `ERR Missing pattern` | `KEYS` missing a pattern |
| `ERR Missing benchmark operation count` | `BENCHMARK` missing operation count |
| `ERR Key cannot be empty` | Empty key rejected |
| `ERR Pattern cannot be empty` | Empty `KEYS` pattern rejected |
| `ERR Invalid pattern for KEYS command` | Store rejected the pattern |
| `ERR Invalid regular expression pattern` | Regex compilation failed |
| `ERR Server out of memory` | Allocation failed |
| `ERR Command execution failed` | Storage command failed, including missing keys |

## Related documents

- [Getting Started](GETTING_STARTED.md)
- [MVP Roadmap](MVP_ROADMAP.md)
- [Server throughput baseline evidence](benchmarks/2026-05-18-server-throughput.md)
