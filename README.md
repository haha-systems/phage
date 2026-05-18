<p align="center">
    <img src="docs/logo-ascii.png" width="300" />
</p>


# Phage
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Phage is a fast key/value store similar to Redis and Valkey, with these goals in mind:

- Achieve one-million key reads per second on consumer hardware
- Use disk storage as the primary storage medium to reduce operating costs
- Be ACID compliant and rock-solid, including data recovery

## A note on the current state of Phage

Phage is written in Zig for speed and safety, and is currently in the early stages of development. Zig is still young, and is continually changing. Equally, this is my first real Zig project. I'm still learning and Phage began as an experiment to get better at Zig and systems programming.

Current local workflows cover the core storage engine, WAL/recovery, the native benchmark runner, protocol command execution, and explicit ZeroMQ server build/run/smoke paths. It is not a production-ready tool right now.

Currently, Phage has achieved the following stats on simple key values:

- Reads: > 1 million keys per second
- Writes: > 300k keys per second

**Benchmark System Specs**

- AMD Ryzen 5600X @ 4.8GHZ
- 16 GB RAM
- 1TB Western Digital SSD

I currently perform the benchmarks on my own PC to push the performance as much as possible, but I expect it to perform much better on server-grade hardware. Linux `io_uring` is the intended high-performance backend; macOS uses a POSIX fallback that is useful for correctness and smoke checks but should not be used for Linux performance claims.

I hope it's useful, but beware that it's not a production-ready tool right now.

- @xiy

## Features

- Write-ahead logging and recovery of entries
- A dual-layer storage mechanism consisting of:
    - A minimal-footprint, in-memory index of key-values
    - Disk-backed storage of key-values through the platform storage backend
- Linux `io_uring` as the intended high-performance backend, with a POSIX fallback for macOS development and tests
- CRC32 checksumming for key-value entry integrity
- Native local benchmark runner with memory/persisted modes and JSON output
- Supported ZeroMQ server build, run, and smoke-test workflow

## Build, test, and benchmark

```sh
zig build
zig build test
zig build --help
```

The supported local performance path is the native benchmark runner:

```sh
# Artifact-free memory-mode smoke
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --read-api get-into --json

# Persisted smoke with a disposable path
zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode persisted --value-size 16 --batch-size 16 --db-path /tmp/phage-readme-bench --json

# Comparable quick matrix: JSON Lines rows plus a compact summary JSON
bench/benchmark-matrix.sh --quick --output /tmp/phage-benchmark-matrix.jsonl
python3 -m json.tool /tmp/phage-benchmark-matrix-summary.json >/dev/null
```

For matrix runs, use `--profile full` for the fuller local profile and keep raw JSONL/summary artifacts under `/tmp` unless a ticket explicitly approves a small curated summary. The current macOS POSIX-fallback quick baseline is documented in [docs/benchmarks/2026-05-18-macos-fallback-baseline.md](docs/benchmarks/2026-05-18-macos-fallback-baseline.md); it must not be treated as Linux `io_uring` performance evidence.

The protocol `BENCHMARK` command is separate from this native benchmark runner. It runs through the server command path and writes benchmark keys into the active store; use the native benchmark command above for reproducible local checks.

## Server workflow

The server workflow is explicit; do not use the default `zig build run` step for the server. Server build/run/smoke steps require the pinned Zig 0.15-compatible `zimq` package from `build.zig.zon` and a working ZeroMQ/libzmq environment. Use `zig build --fetch` if dependencies need to be fetched before offline builds.

```sh
# Build the ZeroMQ server executable
zig build phage-server

# Print server help without opening a socket or database
zig build run-server -- --help

# Start a local server with a disposable store path; press Ctrl-C to stop
zig build run-server -- --db-path /tmp/phage-readme-server --port 5555

# Live MVP command smoke over ZeroMQ; uses and cleans a disposable /tmp store path
zig build server-smoke -- --db-path /tmp/phage-server-smoke

# Bounded repeated multi-client smoke over ZeroMQ; uses and cleans a disposable /tmp store path
zig build server-sustained-smoke -- --db-path /tmp/phage-server-sustained-smoke --clients 2 --requests 100
```

Verified runtime model: multiple ZeroMQ REQ clients can connect and complete repeated request/reply commands, but `src/zserver.zig` uses a single REP loop that serializes receive/execute/send handling. The sustained smoke verifies serialized multi-client REQ/REP behavior; it does not claim parallel command execution, concurrent in-process store access, or throughput scaling with client count.

## Operations

The server text protocol currently supports these commands:

- [x] `PING`: health check returning `PONG`
- [x] `SET key value`: insert a single-token key/value entry
- [x] `GET key`: retrieve a key/value entry
- [x] `DELETE key` / `DEL key`: delete a key/value entry
- [x] `KEYS pattern`: return keys matching `*` or a regex-style pattern such as `user:.*`
- [x] `BENCHMARK operations`: run the protocol/server benchmark path against the active store

Values are whitespace-delimited single tokens; quoted values and values containing spaces are not supported yet.

## Current limitations

- Phage is still early-stage software and is not production-ready.
- Server command execution is serialized through one ZeroMQ REP loop.
- The old external Demon client is not part of this repository and is not required for supported build, test, benchmark, or smoke workflows.
- Server log-level configuration is parsed and printed, but Zig log filtering is still compile-time constrained.
- Final Linux `io_uring` performance verification should be run on a Linux host; macOS POSIX fallback smokes are correctness checks.

## Planned features

- [ ] Sets
- [ ] Ordered Sets
- [ ] JSON blobs
- [ ] Publish/Subscribe
- [ ] Events
- [ ] Queue patterns
- [ ] Bus patterns
- [ ] Vector storage

## Related documents

- [Getting Started](docs/GETTING_STARTED.md)
- [API Reference](docs/API_REFERENCE.md)
- [MVP Roadmap](docs/MVP_ROADMAP.md)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE.md) file for details.

## Contributing

If you want to contribute to make Phage better, I'm very open to pull/feature requests.
