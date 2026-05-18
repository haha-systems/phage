const std = @import("std");
const phage = @import("phage");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const BenchmarkMode = enum {
    persisted,
    memory,
};

const Config = struct {
    ops: u32 = 10_000,
    value_size: usize = 16,
    db_path: []const u8 = "phage_benchmark_store",
    owned_db_path: ?[]u8 = null,
    fresh: bool = true,
    mode: BenchmarkMode = .persisted,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.owned_db_path) |db_path| {
            allocator.free(db_path);
            self.owned_db_path = null;
        }
    }
};

const BenchmarkRunOptions = struct {
    ops: u32,
    value_size: usize = 16,
};

const LatencySummary = struct {
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
};

const BenchmarkStats = struct {
    num_ops: u32,
    write_time_ns: u64,
    read_time_ns: u64,
    total_time_ns: u64,
    write_latency: LatencySummary = .{},
    read_latency: LatencySummary = .{},

    fn writeOpsPerSec(self: BenchmarkStats) f64 {
        return opsPerSec(self.num_ops, self.write_time_ns);
    }

    fn readOpsPerSec(self: BenchmarkStats) f64 {
        return opsPerSec(self.num_ops, self.read_time_ns);
    }

    fn totalOpsPerSec(self: BenchmarkStats) f64 {
        return opsPerSec(@as(u64, self.num_ops) * 2, self.total_time_ns);
    }

    fn opsPerSec(num_ops: u64, elapsed_ns: u64) f64 {
        if (num_ops == 0 or elapsed_ns == 0) return 0.0;
        return @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
    }
};

const MemoryBenchmarkStore = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]u8),

    fn init(allocator: std.mem.Allocator) MemoryBenchmarkStore {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]u8).init(allocator),
        };
    }

    fn deinit(self: *MemoryBenchmarkStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    fn put(self: *MemoryBenchmarkStore, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.map.putNoClobber(owned_key, owned_value);
    }

    fn get(self: *MemoryBenchmarkStore, key: []const u8) ![]u8 {
        const value = self.map.get(key) orelse return error.KeyNotFound;
        return try self.allocator.dupe(u8, value);
    }
};

fn usage(program_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPS] [--mode persisted|memory] [--value-size BYTES] [--db-path PATH] [--reuse]
        \\
        \\Runs the built-in BENCHMARK command locally without requiring the ZMQ server.
        \\
        \\Options:
        \\  OPS                         Number of write/read operations (default: 10000)
        \\  --mode persisted|memory     persisted uses Phage storage; memory uses a HashMap baseline
        \\                              without filesystem or WAL I/O (default: persisted)
        \\  --value-size BYTES          Value payload size to write for each operation (default: 16)
        \\  --db-path PATH              Database path for persisted mode (default: phage_benchmark_store)
        \\  --reuse                     Reuse an existing database instead of deleting it first
        \\  -h, --help                  Show this help
        \\
    , .{program_name});
}

fn parseMode(value: []const u8) !BenchmarkMode {
    if (std.mem.eql(u8, value, "persisted")) return .persisted;
    if (std.mem.eql(u8, value, "memory")) return .memory;
    return error.InvalidBenchmarkMode;
}

fn parseArgSlice(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var config = Config{};
    errdefer config.deinit(allocator);
    var saw_ops = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(args[0]);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--db-path")) {
            i += 1;
            if (i >= args.len) return error.MissingDbPath;
            const owned_path = try allocator.dupe(u8, args[i]);
            if (config.owned_db_path) |old_path| allocator.free(old_path);
            config.db_path = owned_path;
            config.owned_db_path = owned_path;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingBenchmarkMode;
            config.mode = try parseMode(args[i]);
        } else if (std.mem.eql(u8, arg, "--value-size")) {
            i += 1;
            if (i >= args.len) return error.MissingValueSize;
            config.value_size = try std.fmt.parseInt(usize, args[i], 10);
            if (config.value_size == 0) return error.InvalidValueSize;
        } else if (std.mem.eql(u8, arg, "--reuse")) {
            config.fresh = false;
        } else if (!saw_ops) {
            config.ops = try std.fmt.parseInt(u32, arg, 10);
            saw_ops = true;
        } else {
            return error.UnknownArgument;
        }
    }

    return config;
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    return try parseArgSlice(allocator, args);
}

fn removeIfExists(path: []const u8) void {
    std.posix.unlink(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("failed to remove {s}: {s}", .{ path, @errorName(err) }),
    };
}

fn makeValue(allocator: std.mem.Allocator, value_size: usize) ![]u8 {
    const value = try allocator.alloc(u8, value_size);
    @memset(value, 'v');
    return value;
}

fn nearestRank(sorted_samples: []const u64, percentile: u8) u64 {
    if (sorted_samples.len == 0) return 0;
    const rank = (@as(usize, percentile) * sorted_samples.len + 99) / 100;
    const index = @max(@as(usize, 1), rank) - 1;
    return sorted_samples[@min(index, sorted_samples.len - 1)];
}

fn summarizeLatencies(samples: []u64) LatencySummary {
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    return .{
        .p50_ns = nearestRank(samples, 50),
        .p95_ns = nearestRank(samples, 95),
        .p99_ns = nearestRank(samples, 99),
    };
}

fn runBenchmark(store: anytype, options: BenchmarkRunOptions) !BenchmarkStats {
    const write_latencies = try store.allocator.alloc(u64, options.ops);
    defer store.allocator.free(write_latencies);
    const read_latencies = try store.allocator.alloc(u64, options.ops);
    defer store.allocator.free(read_latencies);

    const write_start = std.time.nanoTimestamp();
    for (0..options.ops) |i| {
        const key = try std.fmt.allocPrint(store.allocator, "key{d}", .{i});
        defer store.allocator.free(key);

        const value = try makeValue(store.allocator, options.value_size);
        defer store.allocator.free(value);

        const op_start = std.time.nanoTimestamp();
        try store.put(key, value);
        const op_end = std.time.nanoTimestamp();
        write_latencies[i] = @intCast(op_end - op_start);
    }
    const write_end = std.time.nanoTimestamp();

    var checksum: usize = 0;
    const read_start = std.time.nanoTimestamp();
    for (0..options.ops) |i| {
        const key = try std.fmt.allocPrint(store.allocator, "key{d}", .{i});
        defer store.allocator.free(key);

        const op_start = std.time.nanoTimestamp();
        const value = try store.get(key);
        const op_end = std.time.nanoTimestamp();
        defer store.allocator.free(value);
        read_latencies[i] = @intCast(op_end - op_start);
        checksum +%= value.len;
    }
    const read_end = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(checksum);

    return .{
        .num_ops = options.ops,
        .write_time_ns = @intCast(write_end - write_start),
        .read_time_ns = @intCast(read_end - read_start),
        .total_time_ns = @intCast(read_end - write_start),
        .write_latency = summarizeLatencies(write_latencies),
        .read_latency = summarizeLatencies(read_latencies),
    };
}

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn printBenchmarkStats(stats: BenchmarkStats, writer: *std.io.AnyWriter) !void {
    try writer.print("Write time: {d} ms\n", .{stats.write_time_ns / 1_000_000});
    try writer.print("Read time: {d} ms\n", .{stats.read_time_ns / 1_000_000});
    try writer.print("Total time: {d} ms\n", .{stats.total_time_ns / 1_000_000});
    try writer.print("Write throughput: {d:.2} ops/sec\n", .{stats.writeOpsPerSec()});
    try writer.print("Read throughput: {d:.2} ops/sec\n", .{stats.readOpsPerSec()});
    try writer.print("Total throughput: {d:.2} ops/sec\n", .{stats.totalOpsPerSec()});
    try writer.print("Write latency p50/p95/p99: {d:.2}/{d:.2}/{d:.2} us\n", .{ nsToUs(stats.write_latency.p50_ns), nsToUs(stats.write_latency.p95_ns), nsToUs(stats.write_latency.p99_ns) });
    try writer.print("Read latency p50/p95/p99: {d:.2}/{d:.2}/{d:.2} us\n", .{ nsToUs(stats.read_latency.p50_ns), nsToUs(stats.read_latency.p95_ns), nsToUs(stats.read_latency.p99_ns) });
}

fn runPersistedBenchmark(allocator: std.mem.Allocator, config: Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter().any();
    try stdout.print("Benchmarking...\n", .{});
    try stdout.print("Mode: persisted\n", .{});
    try stdout.print("Value size: {d} bytes\n", .{config.value_size});

    if (config.fresh) {
        removeIfExists(config.db_path);
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{config.db_path});
        defer allocator.free(wal_path);
        removeIfExists(wal_path);
    }

    var store = try phage.Phage.init(allocator, config.db_path);
    defer store.deinit();

    const stats = try runBenchmark(&store, .{ .ops = config.ops, .value_size = config.value_size });
    try printBenchmarkStats(stats, &stdout);
    try stdout.print("Benchmark completed.\n", .{});
}

fn runMemoryBenchmark(allocator: std.mem.Allocator, config: Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter().any();
    try stdout.print("Benchmarking...\n", .{});
    try stdout.print("Mode: memory\n", .{});
    try stdout.print("Value size: {d} bytes\n", .{config.value_size});

    var store = MemoryBenchmarkStore.init(allocator);
    defer store.deinit();

    const stats = try runBenchmark(&store, .{ .ops = config.ops, .value_size = config.value_size });
    try printBenchmarkStats(stats, &stdout);
    try stdout.print("Benchmark completed.\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = parseArgs(allocator) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        usage("phage-benchmark");
        return err;
    };
    defer config.deinit(allocator);

    switch (config.mode) {
        .persisted => try runPersistedBenchmark(allocator, config),
        .memory => try runMemoryBenchmark(allocator, config),
    }
}

test "benchmark args support memory mode for persistence-free baseline" {
    var config = try parseArgSlice(std.testing.allocator, &.{ "phage-benchmark", "42", "--mode", "memory" });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(BenchmarkMode.memory, config.mode);
    try std.testing.expectEqual(@as(u32, 42), config.ops);
    try std.testing.expectEqualStrings("phage_benchmark_store", config.db_path);
}

test "benchmark args support configurable payload size" {
    var config = try parseArgSlice(std.testing.allocator, &.{ "phage-benchmark", "7", "--value-size", "128" });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), config.ops);
    try std.testing.expectEqual(@as(usize, 128), config.value_size);
}

test "benchmark runner writes configured payload bytes" {
    const FakeStore = struct {
        allocator: std.mem.Allocator,
        expected_value_size: usize,
        puts: usize = 0,

        fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            _ = key;
            try std.testing.expectEqual(self.expected_value_size, value.len);
            self.puts += 1;
        }

        fn get(self: *@This(), key: []const u8) ![]u8 {
            _ = key;
            return try self.allocator.alloc(u8, self.expected_value_size);
        }
    };

    var store = FakeStore{ .allocator = std.testing.allocator, .expected_value_size = 128 };
    const stats = try runBenchmark(&store, .{ .ops = 3, .value_size = 128 });

    try std.testing.expectEqual(@as(usize, 3), store.puts);
    try std.testing.expectEqual(@as(u32, 3), stats.num_ops);
}

test "benchmark latency summary uses nearest-rank percentiles" {
    var samples = [_]u64{ 50, 10, 40, 20, 30 };
    const summary = summarizeLatencies(&samples);

    try std.testing.expectEqual(@as(u64, 30), summary.p50_ns);
    try std.testing.expectEqual(@as(u64, 50), summary.p95_ns);
    try std.testing.expectEqual(@as(u64, 50), summary.p99_ns);
}

test "benchmark output includes write and read latency percentiles" {
    const stats = BenchmarkStats{
        .num_ops = 3,
        .write_time_ns = 3000,
        .read_time_ns = 6000,
        .total_time_ns = 9000,
        .write_latency = .{ .p50_ns = 1000, .p95_ns = 2000, .p99_ns = 3000 },
        .read_latency = .{ .p50_ns = 4000, .p95_ns = 5000, .p99_ns = 6000 },
    };

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try printBenchmarkStats(stats, &writer);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Write latency p50/p95/p99") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Read latency p50/p95/p99") != null);
}
