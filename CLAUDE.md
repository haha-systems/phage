# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Phage is a fast key-value database written in Zig that aims to achieve 1 million key reads per second on consumer hardware. It features:
- Asynchronous I/O using `io_uring` for high-performance disk operations
- Write-ahead logging (WAL) for ACID compliance and crash recovery
- Dual-layer storage with in-memory index and disk-backed persistence
- Automatic compaction to manage disk space
- ZeroMQ-based server for network communication

## Build Commands

- **Build**: `zig build`
- **Run server**: `zig build run` 
- **Run tests**: `zig build test`
- **Install**: `zig build install` (creates executable in `zig-out/bin/`)

## Testing

- All tests are located in the `src/` directory alongside source files
- Uses a custom test runner at `src/test_runner.zig`
- Tests are named with the pattern `test "module:function_name"`
- Run individual tests with: `zig build test --summary all`

## Architecture

### Core Components

**Phage Engine** (`src/root.zig`):
- Main database engine with `io_uring` integration
- Handles WAL operations, compaction, and index management
- Entry point for all database operations (put/get/delete)

**Index Manager** (`src/index.zig`):
- Sharded hash map for in-memory key-value index (16 shards by default)
- Thread-safe with per-shard mutexes
- Stores metadata about entries (offset, length, key/value sizes)

**Write-Ahead Log** (`src/io/wal.zig`):
- Provides crash recovery and data integrity
- Each WAL entry includes operation type, key, value lengths, and checksum
- Entries are applied to main storage then WAL is truncated

**ZeroMQ Server** (`src/zserver.zig`):
- Network server using ZeroMQ REP/REQ pattern
- Handles client connections on tcp://*:5555
- Parses and executes protocol commands

### Data Structures

**Buffer Management**: Lock-free buffer pool for I/O operations
**Storage Format**: Custom binary format with headers containing key/value lengths
**Compaction**: Automatic background compaction when waste ratio exceeds 50%

### Protocol

Text-based protocol similar to Redis:
- Commands: SET, GET, DELETE, KEYS, PING
- Format: `[COMMAND] [args...]\n`
- Responses: Status messages or data values

## File Structure

- `src/root.zig` - Main Phage engine
- `src/index.zig` - In-memory index management
- `src/io/` - I/O operations (WAL, async I/O)
- `src/protocol/` - Network protocol definitions
- `src/data_structures/` - Custom data structures (buffer pool, trie, etc.)
- `src/zserver.zig` - ZeroMQ server implementation

## Dependencies

- `colored_logger` - Colored logging output
- `chameleon` - Terminal colors and styling
- `mvzr` - Regular expression support
- `zimq` - ZeroMQ bindings for Zig

## Development Notes

- Uses `io_uring` for high-performance async I/O (Linux-specific)
- Atomic operations for thread-safe counters and flags
- Custom memory management with buffer pools
- CRC32 checksums for data integrity
- Automatic WAL recovery on startup

## Diagnostics

- The easiest way to get fast diagnostics in Zig is to try building the program

## Claude Memories

- You're permitted to save your own relevant memories to the CLAUDE.md file in a section at the bottom of the file

### Development Progress (2025-01-11)

**Phase 1 MVP Objectives - COMPLETED ✅**

- **Server Compilation Fixed**: Resolved `result.payload()` method errors and format string issues in `src/protocol/protocol.zig`
- **Connection Handling**: Modified `src/zserver.zig` to handle multiple requests with proper while loop and continue statements
- **Protocol Implementation**: Core commands (SET/GET/DELETE/PING) working over ZeroMQ network protocol
- **Enhanced Demon Client**: Added command-line mode support to `/home/xiy/code/zig/demon/`
  - Interactive mode: `./demon` (REPL)
  - Command-line mode: `./demon PING`, `./demon SET key value`, etc.

**Testing Setup:**
- Server: `cd /home/xiy/code/zig/phage && zig build run`  
- Client: `cd /home/xiy/code/zig/demon && ./zig-out/bin/demon [command]`
- Integration test: `/home/xiy/code/zig/integration_test.sh`

**Known Issues:**
- KEYS command hangs - `findKeys()` method not implemented in Phage store
- Error handling could be improved for edge cases

**Ready for Phase 2**: Configuration options, benchmarking, error handling improvements

### Source Control Approach

- Use jujutsu with git colocation for source control; commit changes early and often using the conventional commits style