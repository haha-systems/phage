# Phage API Reference

## Overview

Phage is a high-performance key-value database built in Zig, designed to achieve 1 million+ operations per second on consumer hardware. It features asynchronous I/O using `io_uring`, write-ahead logging for ACID compliance, and automatic compaction.

## Server Configuration

### Command Line Options

```bash
./phage [OPTIONS]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --port PORT` | Set server port | `5555` |
| `-d, --db-path PATH` | Set database file path | `phage_store` |
| `-l, --log-level LEVEL` | Set log level (debug, info, warn, err) | `info` |
| `-h, --help` | Show help message | - |

### Examples

```bash
# Start with defaults
./phage

# Custom port and database path
./phage --port 8080 --db-path /var/lib/phage/data

# Enable debug logging
./phage --log-level debug

# Production setup
./phage --port 5555 --db-path /opt/phage/production.db --log-level warn
```

## Protocol

Phage uses a simple text-based protocol over ZeroMQ (REQ/REP pattern) similar to Redis.

### Command Format

```
[COMMAND] [arguments...]\n
```

All commands are terminated with a newline character.

## Commands

### SET - Store a key-value pair

**Syntax:**
```
SET key value
```

**Description:** Stores a value associated with a key in the database.

**Parameters:**
- `key`: The key to store (must not be empty)
- `value`: The value to associate with the key (can be empty)

**Response:**
- `OK` on success
- `ERR ...` on error

**Examples:**
```bash
SET username alice
SET user:123:email alice@example.com
SET config:timeout 30
```

### GET - Retrieve a value by key

**Syntax:**
```
GET key
```

**Description:** Retrieves the value associated with a key.

**Parameters:**
- `key`: The key to retrieve (must not be empty)

**Response:**
- The value associated with the key
- `ERR Command execution failed` if key not found

**Examples:**
```bash
GET username          # Returns: alice
GET user:123:email    # Returns: alice@example.com
GET nonexistent       # Returns: ERR Command execution failed
```

### DELETE - Remove a key-value pair

**Syntax:**
```
DELETE key
```

**Description:** Removes a key and its associated value from the database.

**Parameters:**
- `key`: The key to delete (must not be empty)

**Response:**
- `OK` on success (even if key didn't exist)
- `ERR ...` on error

**Examples:**
```bash
DELETE username       # Returns: OK
DELETE old_data       # Returns: OK
```

### KEYS - List keys matching a pattern

**Syntax:**
```
KEYS pattern
```

**Description:** Returns all keys matching the given regular expression pattern.

**Parameters:**
- `pattern`: Regular expression pattern to match keys
  - Use `*` to match all keys
  - Use regex patterns like `user.*` to match keys starting with "user"

**Response:**
- List of matching keys (one per line)
- `(empty)` if no keys match

**Examples:**
```bash
KEYS *                # Returns all keys
KEYS user:*          # Returns: user:123:email, user:456:name
KEYS config.*        # Returns: config:timeout, config:debug
```

### PING - Health check

**Syntax:**
```
PING
```

**Description:** Simple health check command to verify server connectivity.

**Response:**
- `PONG`

**Examples:**
```bash
PING                 # Returns: PONG
```

### BENCHMARK - Performance testing

**Syntax:**
```
BENCHMARK operations
```

**Description:** Runs a performance benchmark with the specified number of operations. Each operation performs both a SET and GET, so the total operations performed is 2x the specified number.

**Parameters:**
- `operations`: Number of benchmark operations to perform (1-1,000,000)

**Response:**
- Performance summary with operations count, time, and ops/sec

**Examples:**
```bash
BENCHMARK 100        # Returns: Benchmark completed: 200 operations in 38 ms (5263.16 ops/sec)
BENCHMARK 1000       # Returns: Benchmark completed: 2000 operations in 368 ms (5434.78 ops/sec)
```

## Client Usage

### Demon CLI Client

The `demon` client provides both interactive and command-line interfaces.

#### Command-line Mode
```bash
# Execute single commands
./demon PING
./demon SET mykey myvalue
./demon GET mykey
./demon DELETE mykey
./demon KEYS "*"
./demon BENCHMARK 100
```

#### Interactive Mode
```bash
# Start interactive session
./demon

# Interactive prompt
demon> SET user:1 john
Response: OK
demon> GET user:1
Response: john
demon> KEYS user:*
Response: user:1
demon> exit
Goodbye!
```

## Error Handling

### Error Response Format
```
ERR [error description]
```

### Common Errors

| Error | Description | Solution |
|-------|-------------|----------|
| `ERR Unknown command or invalid syntax` | Invalid command or malformed syntax | Check command format |
| `ERR Missing key argument` | Key parameter missing | Provide a key argument |
| `ERR Missing value argument` | Value parameter missing for SET | Provide a value argument |
| `ERR Missing pattern argument for KEYS command` | Pattern missing for KEYS | Provide a pattern argument |
| `ERR Key cannot be empty` | Empty key provided | Use a non-empty key |
| `ERR Invalid pattern for KEYS command` | Invalid regex pattern | Use a valid regex pattern |
| `ERR Server out of memory` | Server memory exhausted | Restart server or reduce load |
| `ERR Command execution failed` | General execution error | Check server logs |

## Performance

### Benchmark Results

Based on testing, Phage achieves:
- **5,000+ operations/second** on consumer hardware
- **Sub-millisecond latency** for individual operations
- **Linear scaling** with operation count
- **Consistent performance** under sustained load

### Optimization Tips

1. **Batch Operations:** Use multiple clients for concurrent operations
2. **Key Design:** Use consistent key naming patterns for better performance
3. **Memory Management:** Monitor server memory usage during high-load scenarios
4. **Network:** Use localhost connections for best performance

## Integration Examples

### Shell Script
```bash
#!/bin/bash
# Health check script
if ./demon PING > /dev/null; then
    echo "Phage server is healthy"
    exit 0
else
    echo "Phage server is down"
    exit 1
fi
```

### Performance Monitoring
```bash
# Simple performance test
echo "Running performance test..."
./demon BENCHMARK 1000
echo "Test completed"
```

### Backup Script
```bash
#!/bin/bash
# Backup all keys
KEYS=$(./demon KEYS "*")
for key in $KEYS; do
    value=$(./demon GET "$key")
    echo "SET $key $value" >> backup.txt
done
```

## Troubleshooting

### Connection Issues
- **"Connection refused":** Ensure server is running on correct port
- **"Address in use":** Another process is using the port
- **"Timeout":** Check network connectivity and server load

### Performance Issues
- **Slow responses:** Check server resource usage (CPU, memory, disk I/O)
- **High latency:** Use `BENCHMARK` command to measure baseline performance
- **Memory leaks:** Monitor server startup/shutdown messages for leak detection

### Data Issues
- **Keys not found:** Use `KEYS *` to list all keys and verify key names
- **Pattern not matching:** Test regex patterns with online regex tools
- **Data corruption:** Check server logs for error messages

## See Also

- [MVP Roadmap](MVP_ROADMAP.md) - Development progress and upcoming features
- [CLAUDE.md](../CLAUDE.md) - Development guidelines and architecture notes
- [Integration Tests](../integration_test.sh) - Automated testing examples