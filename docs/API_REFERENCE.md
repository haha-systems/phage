# Phage API Reference

## Current build and server status

Phage currently builds the core library and native benchmark runner through `build.zig`:

```sh
zig build
zig build test
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into
```

The ZeroMQ server implementation lives in `src/zserver.zig`, but it is not wired into the default Zig build graph at this time. `zig build --help` lists `install`, `test`, and `benchmark`; there is no supported `zig build run` server step. The command-line options below describe the current `zserver.zig` implementation if/when that executable is built separately.

## Server configuration implemented in `src/zserver.zig`

```sh
phage-server [OPTIONS]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --port PORT` | Set ZeroMQ REP server port | `5555` |
| `-d, --db-path PATH` | Set database file path | `phage_store` |
| `-l, --log-level LEVEL` | Requested log level (`debug`, `info`, `warn`, `err`) | `info` |
| `-h, --help` | Show help message | - |

The log-level flag is currently reported at startup; it does not dynamically reconfigure Zig's compile-time log filtering.

## Core store API

The core Zig store type is `Phage` in `src/root.zig`.

| Method | Ownership and behavior |
|--------|------------------------|
| `put(key, value)` | Stores the key/value pair and updates the WAL and index. |
| `putBatch(pairs)` | Stores multiple key/value pairs with coalesced data/WAL writes. |
| `get(key)` | Returns an allocator-owned copy of the value. The caller must free the returned slice with the store allocator. Existing allocation-owning behavior is preserved. |
| `getInto(key, buffer)` | Reads the value into caller-provided storage and returns the populated subslice. The returned slice points into `buffer`; no value allocation is performed. Returns `error.InsufficientBuffer` when `buffer.len` is smaller than the stored value, `error.KeyNotFound` for missing keys, and `error.KeyMismatch` if the indexed key does not match the bytes read from storage. |
| `delete(key)` | Removes the key from the index and records a delete WAL entry. |
| `findKeys(pattern)` | Returns keys matching the regex-style pattern or `null` when none match. |

`getInto` is intended for read paths that can reuse buffers across calls, such as benchmarks or services that already own request/response storage. Use `get` when caller-owned allocation is more convenient.

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
