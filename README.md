<p align="center">
    <img src="docs/logo-ascii.png" width="300" />
</p>

# Phage

Phage is a fast key/value store similar to Redis and Valkey, with these goals in mind:

- Achieve one-million key reads per second on consumer hardware
- Use disk storage as the primary storage medium to reduce operating costs
- Be ACID compliant and rock-solid, including data recovery

## A note on the current state of Phage

Phage is written in Zig for speed and safety, and is currently in the early stages of development. Zig is still young, and is continually changing. Equally, this is my first real Zig project. I'm still learning and Phage began as an experiment to get better at Zig and systems programming.

Currently, Phage has achieved the following stats on simple key values:

- Reads: > 1 million keys per second
- Writes: > 300k keys per second

**Benchmark System Specs**

- AMD Ryzen 5600X @ 4.8GHZ
- 16 GB RAM
- 1TB Western Digital SSD

I currently perform the benchmarks on my own PC to push the performance as much as possible, but I expect it to perform much better on server-grade hardware.

I hope it's useful, but beware that its not a production-ready tool right now.

- @xiy

## Features

- Asynchronous file I/O using `io_uring`
- Write-ahead logging and recovery of entries
- A dual-layer storage mechanism consisting of:
    - A mininal footprint, in-memory index of key-values
    - A disk-backed storage of keys-values through `io_uring`
- CRC32 checksumming for key-value entry integrity

### Operations

Phage currently supports the following operations. You can interact directly with the database using the CLI, called **Demon**.

- [x] **put (key, value)**: insert a new key/value entry into the database
- [x] **get (key)**: retrieve a key/value entry by it's key name
- [x] **delete (key)**: delete a key/value entry` from the database
- [x] **keys (pattern)**: return keys from the database matching a regex pattern
- [x] **exit**: quits Demon

#### TODO

- [] **bench (n)**: benchmark the database, inserting and then retrieving _n_ key-values
- [] **recover-wal**: force a recovery of the database using the write-ahead log
- [] **recover-index**: force a recovery of the database from storage

### Clients

Phage currently only has a single client; a terminal CLI for direct access to the database. In the future, Phage will include a clustered server and libraries for common languages like Go, Ruby, and JavaScript.

## Planned features

- [] Sets
- [] Ordered Sets
- [] JSON blobs
- [] Publish/Subscribe
- [] Events
- [] Queue patterns
- [] Bus patterns
- [] Vector storage