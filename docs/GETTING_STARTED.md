# Getting Started with Phage

## What is Phage?

Phage is a lightning-fast key-value database written in Zig that achieves 1 million+ reads per second on consumer hardware. It features:

- ⚡ **High Performance:** Built with `io_uring` for asynchronous I/O
- 🔐 **ACID Compliance:** Write-ahead logging ensures data integrity
- 💾 **Persistent Storage:** Automatic compaction and crash recovery
- 🌐 **Network Protocol:** ZeroMQ-based server with simple text protocol
- 🔧 **Easy Configuration:** Command-line configuration options

## Quick Start

### Prerequisites

- Linux system (required for `io_uring`)
- Zig 0.14.0 or later

### Installation

1. **Clone and build Phage server:**
```bash
cd /path/to/phage
zig build
```

2. **Clone and build Demon client:**
```bash
cd /path/to/demon
zig build
```

### Start the Server

```bash
# Start with default settings (port 5555, local database)
./zig-out/bin/phage

# Start with custom configuration
./zig-out/bin/phage --port 8080 --db-path /tmp/mydb --log-level debug
```

You should see:
```
Starting Phage server with configuration:
  Port: 5555
  Database: phage_store
  Log Level: log.Level.info
info: Phage starting...
info: Rebuilding index...
info: Index rebuilt.
info: Checking WAL recovery entries...
info: WAL recovery completed.
info: Phage started successfully.
```

## Your First Commands

### Using the Demon Client

#### 1. Health Check
```bash
./demon PING
# Output: PONG
```

#### 2. Store Some Data
```bash
./demon SET greeting "Hello, World!"
# Output: OK

./demon SET user:1001:name "Alice Johnson"
# Output: OK

./demon SET user:1001:email "alice@example.com"
# Output: OK
```

#### 3. Retrieve Data
```bash
./demon GET greeting
# Output: Hello, World!

./demon GET user:1001:name
# Output: Alice Johnson
```

#### 4. List Keys
```bash
./demon KEYS "*"
# Output:
# greeting
# user:1001:name
# user:1001:email

./demon KEYS "user:*"
# Output:
# user:1001:name
# user:1001:email
```

#### 5. Performance Test
```bash
./demon BENCHMARK 1000
# Output: Benchmark completed: 2000 operations in 368 ms (5434.78 ops/sec)
```

## Interactive Mode

For exploration and development, use the interactive REPL:

```bash
./demon
```

```
Demon Client - Interactive Mode
Type commands (SET key value, GET key, DELETE key, PING, KEYS pattern)
Press Ctrl+C to exit

demon> SET temperature 72
Response: OK
demon> GET temperature
Response: 72
demon> KEYS temp*
Response: temperature
demon> DELETE temperature
Response: OK
demon> exit
Goodbye!
```

## Common Use Cases

### 1. Session Storage
```bash
# Store user session
./demon SET session:abc123 "user_id:1001,expires:1640995200"

# Retrieve session
./demon GET session:abc123

# Clean up expired sessions
./demon DELETE session:abc123
```

### 2. Configuration Cache
```bash
# Store application config
./demon SET config:max_connections 100
./demon SET config:timeout 30
./demon SET config:debug_mode true

# Retrieve all config
./demon KEYS "config:*"
```

### 3. Counters and Metrics
```bash
# Simple counters (note: atomic operations not yet implemented)
./demon SET counter:page_views 1000
./demon SET counter:api_calls 5432
./demon SET counter:errors 12

# Retrieve metrics
./demon KEYS "counter:*"
```

### 4. Data Migration Testing
```bash
# Test data migration performance
./demon BENCHMARK 10000

# Verify data integrity
./demon SET test_key test_value
./demon GET test_key
./demon DELETE test_key
```

## Production Setup

### Server Configuration

For production environments:

```bash
# Production server with custom settings
./phage \
  --port 5555 \
  --db-path /var/lib/phage/production.db \
  --log-level warn
```

### Health Monitoring

Create a health check script:

```bash
#!/bin/bash
# health_check.sh
if ./demon PING > /dev/null 2>&1; then
    echo "✅ Phage server is healthy"
    exit 0
else
    echo "❌ Phage server is down"
    exit 1
fi
```

### Performance Monitoring

Monitor performance regularly:

```bash
#!/bin/bash
# performance_check.sh
echo "🔍 Running performance test..."
result=$(./demon BENCHMARK 1000)
echo "📊 $result"

# Extract ops/sec for monitoring
ops_per_sec=$(echo "$result" | grep -o '[0-9]*\.[0-9]* ops/sec')
echo "⚡ Performance: $ops_per_sec"
```

### Backup Strategy

Simple backup approach:

```bash
#!/bin/bash
# backup.sh
timestamp=$(date +%Y%m%d_%H%M%S)
backup_file="backup_$timestamp.txt"

echo "💾 Creating backup: $backup_file"
keys=$(./demon KEYS "*")
echo "📝 Found $(echo "$keys" | wc -l) keys"

for key in $keys; do
    value=$(./demon GET "$key")
    echo "SET \"$key\" \"$value\"" >> "$backup_file"
done

echo "✅ Backup completed: $backup_file"
```

## Configuration Options

### Server Options

| Option | Environment | Description | Example |
|--------|-------------|-------------|---------|
| `--port` | Development | Custom port | `--port 8080` |
| `--db-path` | Production | Database location | `--db-path /var/lib/phage/data` |
| `--log-level` | Debug | Logging verbosity | `--log-level debug` |

### Environment-Specific Configurations

#### Development
```bash
./phage --port 5555 --log-level debug
```

#### Testing
```bash
./phage --port 5556 --db-path /tmp/test_db --log-level info
```

#### Production
```bash
./phage --port 5555 --db-path /opt/phage/prod.db --log-level warn
```

## Troubleshooting

### Common Issues

#### Server Won't Start
```bash
# Check if port is in use
netstat -tulpn | grep 5555

# Kill existing processes
pkill -f phage

# Start with different port
./phage --port 5556
```

#### Client Connection Failed
```bash
# Verify server is running
./demon PING

# Check server logs for errors
./phage --log-level debug
```

#### Performance Issues
```bash
# Run benchmark to check baseline performance
./demon BENCHMARK 100

# Monitor system resources
top
iostat 1

# Check for memory leaks in server output
# Look for "Memory leaks detected" vs "No memory leaks detected"
```

#### Data Not Persisting
```bash
# Verify database files exist
ls -la phage_store*

# Check WAL recovery messages in server startup
```

### Getting Help

1. **Check the logs:** Server startup messages provide valuable debugging info
2. **Run benchmarks:** Use `BENCHMARK` command to verify performance
3. **Test connectivity:** Use `PING` command to verify server is responding
4. **Verify commands:** Check [API Reference](API_REFERENCE.md) for correct syntax

## Next Steps

### Explore Advanced Features
- Review [API Reference](API_REFERENCE.md) for complete command documentation
- Check [MVP Roadmap](MVP_ROADMAP.md) for upcoming features
- Examine [integration tests](../integration_test.sh) for automation examples

### Integration Ideas
- **Web Applications:** Use as session store or cache
- **Microservices:** Service discovery and configuration management
- **IoT:** High-frequency sensor data storage
- **Gaming:** Player state and leaderboards
- **Analytics:** Real-time counters and metrics

### Performance Optimization
- **Concurrent Clients:** Run multiple demon clients for parallel operations
- **Batch Operations:** Group related operations together
- **Key Design:** Use consistent naming patterns for better locality
- **Memory Monitoring:** Watch for memory usage during sustained loads

## Example Scripts

### Data Population Script
```bash
#!/bin/bash
# populate_data.sh
echo "🚀 Populating test data..."

for i in {1..100}; do
    ./demon SET "user:$i:name" "User$i"
    ./demon SET "user:$i:email" "user$i@example.com"
    ./demon SET "user:$i:score" $((RANDOM % 1000))
done

echo "✅ Created 300 entries"
./demon KEYS "user:*" | wc -l
```

### Performance Test Suite
```bash
#!/bin/bash
# perf_test.sh
echo "📊 Performance Test Suite"
echo "========================="

for size in 100 500 1000 5000; do
    echo "Testing $size operations..."
    result=$(./demon BENCHMARK $size)
    echo "$result"
    echo "---"
done
```

Welcome to Phage! 🚀