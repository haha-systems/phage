const std = @import("std");
const builtin = @import("builtin");
const phage = @import("phage");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const BenchmarkMode = enum {
    persisted,
    memory,
};

const OutputFormat = enum {
    human,
    json,
};

const ReadApi = enum {
    get,
    get_into,
};

const WorkloadProfile = enum {
    standard,
    compaction,
};

const DEFAULT_COMPACTION_UPDATE_ROUNDS: u32 = 2;

const Config = struct {
    ops: u32 = 10_000,
    value_size: usize = 16,
    batch_size: usize = 1,
    db_path: []const u8 = "phage_benchmark_store",
    owned_db_path: ?[]u8 = null,
    fresh: bool = true,
    mode: BenchmarkMode = .persisted,
    output_format: OutputFormat = .human,
    read_api: ReadApi = .get,
    workload_profile: WorkloadProfile = .standard,
    update_rounds: u32 = DEFAULT_COMPACTION_UPDATE_ROUNDS,

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
    batch_size: usize = 1,
    read_api: ReadApi = .get,
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

const CompactionBenchmarkStats = struct {
    live_key_count: u32,
    update_rounds: u32,
    value_size: usize,
    operation_count: u32,
    write_time_ns: u64,
    write_latency: LatencySummary = .{},
    compaction_triggered: bool = false,
    compaction_trigger_count: u32 = 0,
    waste_ratio_before: f64 = 0.0,
    waste_ratio_after: f64 = 0.0,
    file_size_before: u64 = 0,
    file_size_after: u64 = 0,
    file_size_reduction_bytes: u64 = 0,
    trigger_latency_ns: u64 = 0,

    fn writeOpsPerSec(self: CompactionBenchmarkStats) f64 {
        return BenchmarkStats.opsPerSec(self.operation_count, self.write_time_ns);
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

    fn putBatch(self: *MemoryBenchmarkStore, pairs: []const phage.Phage.BatchPair) !void {
        for (pairs) |pair| {
            try self.put(pair.key, pair.value);
        }
    }

    fn get(self: *MemoryBenchmarkStore, key: []const u8) ![]u8 {
        const value = self.map.get(key) orelse return error.KeyNotFound;
        return try self.allocator.dupe(u8, value);
    }

    fn getInto(self: *MemoryBenchmarkStore, key: []const u8, buffer: []u8) ![]u8 {
        const value = self.map.get(key) orelse return error.KeyNotFound;
        if (buffer.len < value.len) return error.InsufficientBuffer;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
};

fn usage(program_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPS] [--mode persisted|memory] [--profile standard|compaction] [--value-size BYTES] [--batch-size N] [--read-api get|get-into] [--update-rounds N] [--db-path PATH] [--reuse] [--json]
        \\
        \\Runs the built-in BENCHMARK command locally without requiring the ZMQ server.
        \\
        \\Options:
        \\  OPS                         Number of write/read operations for standard profile;
        \\                              live-key count for compaction profile (default: 10000)
        \\  --mode persisted|memory     persisted uses Phage storage; memory uses a HashMap baseline
        \\                              without filesystem or WAL I/O (default: persisted)
        \\  --profile standard|compaction
        \\                              standard runs ordinary put/get; compaction runs update-heavy
        \\                              persisted puts and reports compaction metrics (default: standard)
        \\  --value-size BYTES          Value payload size to write for each operation (default: 16)
        \\  --batch-size N              Number of writes to group before waiting (default: 1)
        \\  --read-api get|get-into     Read API to measure: allocating get or caller-buffer getInto (default: get)
        \\  --update-rounds N           Compaction profile update rounds after initial live-key load (default: 2)
        \\  --buffered-reads            Alias for --read-api get-into
        \\  --db-path PATH              Database path for persisted mode (default: phage_benchmark_store)
        \\  --reuse                     Reuse an existing database instead of deleting it first
        \\  --json                      Emit machine-readable JSON instead of human text
        \\  -h, --help                  Show this help
        \\
    , .{program_name});
}

fn parseMode(value: []const u8) !BenchmarkMode {
    if (std.mem.eql(u8, value, "persisted")) return .persisted;
    if (std.mem.eql(u8, value, "memory")) return .memory;
    return error.InvalidBenchmarkMode;
}

fn parseReadApi(value: []const u8) !ReadApi {
    if (std.mem.eql(u8, value, "get")) return .get;
    if (std.mem.eql(u8, value, "get-into") or std.mem.eql(u8, value, "getInto")) return .get_into;
    return error.InvalidReadApi;
}

fn parseWorkloadProfile(value: []const u8) !WorkloadProfile {
    if (std.mem.eql(u8, value, "standard")) return .standard;
    if (std.mem.eql(u8, value, "compaction")) return .compaction;
    return error.InvalidWorkloadProfile;
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
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingWorkloadProfile;
            config.workload_profile = try parseWorkloadProfile(args[i]);
        } else if (std.mem.eql(u8, arg, "--value-size")) {
            i += 1;
            if (i >= args.len) return error.MissingValueSize;
            config.value_size = try std.fmt.parseInt(usize, args[i], 10);
            if (config.value_size == 0) return error.InvalidValueSize;
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            i += 1;
            if (i >= args.len) return error.MissingBatchSize;
            config.batch_size = try std.fmt.parseInt(usize, args[i], 10);
            if (config.batch_size == 0) return error.InvalidBatchSize;
        } else if (std.mem.eql(u8, arg, "--read-api")) {
            i += 1;
            if (i >= args.len) return error.MissingReadApi;
            config.read_api = try parseReadApi(args[i]);
        } else if (std.mem.eql(u8, arg, "--update-rounds")) {
            i += 1;
            if (i >= args.len) return error.MissingUpdateRounds;
            config.update_rounds = try std.fmt.parseInt(u32, args[i], 10);
            if (config.update_rounds == 0) return error.InvalidUpdateRounds;
        } else if (std.mem.eql(u8, arg, "--buffered-reads")) {
            config.read_api = .get_into;
        } else if (std.mem.eql(u8, arg, "--reuse")) {
            config.fresh = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output_format = .json;
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

fn freeBatch(allocator: std.mem.Allocator, pairs: []const phage.Phage.BatchPair) void {
    for (pairs) |pair| {
        allocator.free(pair.key);
        allocator.free(pair.value);
    }
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

    const batch_size = @max(@as(usize, 1), options.batch_size);
    const batch_capacity = @min(batch_size, @as(usize, options.ops));
    const pairs = try store.allocator.alloc(phage.Phage.BatchPair, batch_capacity);
    defer store.allocator.free(pairs);

    const write_start = std.time.nanoTimestamp();
    var write_index: usize = 0;
    while (write_index < options.ops) {
        const batch_len = @min(batch_capacity, @as(usize, options.ops) - write_index);
        for (pairs[0..batch_len], 0..) |*pair, batch_index| {
            const op_index = write_index + batch_index;
            pair.* = .{
                .key = try std.fmt.allocPrint(store.allocator, "key{d}", .{op_index}),
                .value = try makeValue(store.allocator, options.value_size),
            };
        }

        const op_start = std.time.nanoTimestamp();
        if (batch_len == 1 and batch_size == 1) {
            try store.put(pairs[0].key, pairs[0].value);
        } else {
            try store.putBatch(pairs[0..batch_len]);
        }
        const op_end = std.time.nanoTimestamp();
        const per_item_ns = @max(@as(u64, 1), @as(u64, @intCast(op_end - op_start)) / @as(u64, @intCast(batch_len)));
        @memset(write_latencies[write_index .. write_index + batch_len], per_item_ns);
        freeBatch(store.allocator, pairs[0..batch_len]);

        write_index += batch_len;
    }
    const write_end = std.time.nanoTimestamp();

    var reusable_read_buffer: ?[]u8 = null;
    if (options.read_api == .get_into) {
        reusable_read_buffer = try store.allocator.alloc(u8, options.value_size);
    }
    defer if (reusable_read_buffer) |buffer| store.allocator.free(buffer);

    var checksum: usize = 0;
    const read_start = std.time.nanoTimestamp();
    for (0..options.ops) |i| {
        const key = try std.fmt.allocPrint(store.allocator, "key{d}", .{i});
        defer store.allocator.free(key);

        const op_start = std.time.nanoTimestamp();
        const value = switch (options.read_api) {
            .get => blk: {
                const allocated = try store.get(key);
                defer store.allocator.free(allocated);
                break :blk allocated.len;
            },
            .get_into => blk: {
                const read_buffer = reusable_read_buffer.?;
                const buffered = try store.getInto(key, read_buffer);
                break :blk buffered.len;
            },
        };
        const op_end = std.time.nanoTimestamp();
        read_latencies[i] = @intCast(op_end - op_start);
        checksum +%= value;
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

fn benchmarkModeName(mode: BenchmarkMode) []const u8 {
    return switch (mode) {
        .persisted => "persisted",
        .memory => "memory",
    };
}

fn readApiName(read_api: ReadApi) []const u8 {
    return switch (read_api) {
        .get => "get",
        .get_into => "getInto",
    };
}

fn workloadProfileName(profile: WorkloadProfile) []const u8 {
    return switch (profile) {
        .standard => "standard",
        .compaction => "compaction",
    };
}

fn backendStatusName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos-posix-fallback",
        .linux => "linux-io-uring-intended",
        else => "posix-fallback",
    };
}

fn printBenchmarkJson(config: Config, stats: BenchmarkStats, writer: *std.io.AnyWriter) !void {
    try writer.writeAll("{\"workload_profile\":\"");
    try writer.writeAll(workloadProfileName(config.workload_profile));
    try writer.writeAll("\",\"mode\":\"");
    try writer.writeAll(benchmarkModeName(config.mode));
    try writer.writeAll("\"");
    try writer.print(",\"operation_count\":{d},\"value_size\":{d},\"batch_size\":{d}", .{
        config.ops,
        config.value_size,
        config.batch_size,
    });
    try writer.writeAll(",\"read_api\":\"");
    try writer.writeAll(readApiName(config.read_api));
    try writer.writeAll("\"");
    try writer.writeAll(",\"backend_status\":\"");
    try writer.writeAll(backendStatusName());
    try writer.writeAll("\"");
    try writer.writeAll(",\"throughput\":{");
    try writer.print("\"write_ops_per_sec\":{d:.2},\"read_ops_per_sec\":{d:.2},\"total_ops_per_sec\":{d:.2}", .{
        stats.writeOpsPerSec(),
        stats.readOpsPerSec(),
        stats.totalOpsPerSec(),
    });
    try writer.writeAll("},\"latency_us\":{\"write\":{");
    try writer.print("\"p50\":{d:.2},\"p95\":{d:.2},\"p99\":{d:.2}", .{
        nsToUs(stats.write_latency.p50_ns),
        nsToUs(stats.write_latency.p95_ns),
        nsToUs(stats.write_latency.p99_ns),
    });
    try writer.writeAll("},\"read\":{");
    try writer.print("\"p50\":{d:.2},\"p95\":{d:.2},\"p99\":{d:.2}", .{
        nsToUs(stats.read_latency.p50_ns),
        nsToUs(stats.read_latency.p95_ns),
        nsToUs(stats.read_latency.p99_ns),
    });
    try writer.writeAll("}}}\n");
}

fn printBenchmarkStats(config: Config, stats: BenchmarkStats, writer: *std.io.AnyWriter) !void {
    try writer.print("Read API: {s}\n", .{readApiName(config.read_api)});
    try writer.print("Write time: {d} ms\n", .{stats.write_time_ns / 1_000_000});
    try writer.print("Read time: {d} ms\n", .{stats.read_time_ns / 1_000_000});
    try writer.print("Total time: {d} ms\n", .{stats.total_time_ns / 1_000_000});
    try writer.print("Write throughput: {d:.2} ops/sec\n", .{stats.writeOpsPerSec()});
    try writer.print("Read throughput: {d:.2} ops/sec\n", .{stats.readOpsPerSec()});
    try writer.print("Total throughput: {d:.2} ops/sec\n", .{stats.totalOpsPerSec()});
    try writer.print("Write latency p50/p95/p99: {d:.2}/{d:.2}/{d:.2} us\n", .{ nsToUs(stats.write_latency.p50_ns), nsToUs(stats.write_latency.p95_ns), nsToUs(stats.write_latency.p99_ns) });
    try writer.print("Read latency p50/p95/p99: {d:.2}/{d:.2}/{d:.2} us\n", .{ nsToUs(stats.read_latency.p50_ns), nsToUs(stats.read_latency.p95_ns), nsToUs(stats.read_latency.p99_ns) });
}

fn printCompactionBenchmarkJson(config: Config, stats: CompactionBenchmarkStats, writer: *std.io.AnyWriter) !void {
    try writer.writeAll("{\"workload_profile\":\"compaction\",\"mode\":\"persisted\"");
    try writer.print(",\"operation_count\":{d},\"live_key_count\":{d},\"value_size\":{d},\"update_rounds\":{d},\"batch_size\":{d}", .{
        stats.operation_count,
        stats.live_key_count,
        stats.value_size,
        stats.update_rounds,
        config.batch_size,
    });
    try writer.writeAll(",\"read_api\":\"");
    try writer.writeAll(readApiName(config.read_api));
    try writer.writeAll("\",\"backend_status\":\"");
    try writer.writeAll(backendStatusName());
    try writer.writeAll("\",\"throughput\":{");
    try writer.print("\"write_ops_per_sec\":{d:.2}", .{stats.writeOpsPerSec()});
    try writer.writeAll("},\"latency_us\":{\"write\":{");
    try writer.print("\"p50\":{d:.2},\"p95\":{d:.2},\"p99\":{d:.2}", .{
        nsToUs(stats.write_latency.p50_ns),
        nsToUs(stats.write_latency.p95_ns),
        nsToUs(stats.write_latency.p99_ns),
    });
    try writer.writeAll("},\"trigger\":");
    try writer.print("{d:.2}", .{nsToUs(stats.trigger_latency_ns)});
    try writer.writeAll("}");
    try writer.writeAll(",\"compaction\":{");
    try writer.print("\"triggered\":{},\"trigger_count\":{d},\"waste_ratio_before\":{d:.6},\"waste_ratio_after\":{d:.6},\"file_size_before\":{d},\"file_size_after\":{d},\"file_size_reduction_bytes\":{d}", .{
        stats.compaction_triggered,
        stats.compaction_trigger_count,
        stats.waste_ratio_before,
        stats.waste_ratio_after,
        stats.file_size_before,
        stats.file_size_after,
        stats.file_size_reduction_bytes,
    });
    try writer.writeAll("}}\n");
}

fn printCompactionBenchmarkStats(stats: CompactionBenchmarkStats, writer: *std.io.AnyWriter) !void {
    try writer.print("Compaction benchmark profile\n", .{});
    try writer.print("Mode: persisted\n", .{});
    try writer.print("Backend status: {s}\n", .{backendStatusName()});
    try writer.print("Operation count: {d}\n", .{stats.operation_count});
    try writer.print("Live key count: {d}\n", .{stats.live_key_count});
    try writer.print("Value size: {d} bytes\n", .{stats.value_size});
    try writer.print("Update rounds: {d}\n", .{stats.update_rounds});
    try writer.print("Compaction triggered: {}\n", .{stats.compaction_triggered});
    try writer.print("Compaction trigger count: {d}\n", .{stats.compaction_trigger_count});
    try writer.print("Waste ratio before/after: {d:.4}/{d:.4}\n", .{ stats.waste_ratio_before, stats.waste_ratio_after });
    try writer.print("File size before/after/reduction: {d}/{d}/{d} bytes\n", .{ stats.file_size_before, stats.file_size_after, stats.file_size_reduction_bytes });
    try writer.print("Write throughput: {d:.2} ops/sec\n", .{stats.writeOpsPerSec()});
    try writer.print("Write latency p50/p95/p99: {d:.2}/{d:.2}/{d:.2} us\n", .{ nsToUs(stats.write_latency.p50_ns), nsToUs(stats.write_latency.p95_ns), nsToUs(stats.write_latency.p99_ns) });
    try writer.print("Compaction trigger latency: {d:.2} us\n", .{nsToUs(stats.trigger_latency_ns)});
}

fn removeStoreArtifacts(allocator: std.mem.Allocator, db_path: []const u8) void {
    removeIfExists(db_path);
    const wal_path = std.fmt.allocPrint(allocator, "{s}.wal", .{db_path}) catch return;
    defer allocator.free(wal_path);
    removeIfExists(wal_path);
    const compact_path = std.fmt.allocPrint(allocator, "{s}.compact.tmp", .{db_path}) catch return;
    defer allocator.free(compact_path);
    removeIfExists(compact_path);
}

fn requireTmpPath(db_path: []const u8) !void {
    if (!std.mem.startsWith(u8, db_path, "/tmp/")) return error.CompactionDbPathMustBeUnderTmp;
}

fn runCompactionWorkload(allocator: std.mem.Allocator, store: *phage.Phage, config: Config) !CompactionBenchmarkStats {
    if (config.ops == 0) return error.InvalidOperationCount;
    const operation_count_u64 = @as(u64, config.ops) * (@as(u64, config.update_rounds) + 1);
    if (operation_count_u64 > std.math.maxInt(u32)) return error.OperationCountTooLarge;
    const operation_count: u32 = @intCast(operation_count_u64);

    const write_latencies = try allocator.alloc(u64, operation_count);
    defer allocator.free(write_latencies);

    const value = try makeValue(allocator, config.value_size);
    defer allocator.free(value);

    var op_index: usize = 0;
    var compaction_triggered = false;
    var compaction_trigger_count: u32 = 0;
    var peak_waste_before: f64 = 0.0;
    var file_size_before: u64 = store.file_size.load(.monotonic);
    var file_size_reduction_bytes: u64 = 0;
    var trigger_latency_ns: u64 = 0;

    const write_start = std.time.nanoTimestamp();
    for (0..config.ops) |key_index| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{key_index});
        defer allocator.free(key);

        const op_start = std.time.nanoTimestamp();
        try store.put(key, value);
        const op_end = std.time.nanoTimestamp();
        write_latencies[op_index] = @intCast(op_end - op_start);
        op_index += 1;
    }

    for (0..config.update_rounds) |_| {
        for (0..config.ops) |key_index| {
            const key = try std.fmt.allocPrint(allocator, "key{d}", .{key_index});
            defer allocator.free(key);

            const before_size = store.file_size.load(.monotonic);
            const before_waste = store.calculateMainFileWasteRatio();
            peak_waste_before = @max(peak_waste_before, before_waste);

            const op_start = std.time.nanoTimestamp();
            try store.put(key, value);
            const op_end = std.time.nanoTimestamp();
            const elapsed_ns: u64 = @intCast(op_end - op_start);
            write_latencies[op_index] = elapsed_ns;
            op_index += 1;

            const after_size = store.file_size.load(.monotonic);
            if (after_size < before_size) {
                compaction_triggered = true;
                compaction_trigger_count += 1;
                file_size_before = @max(file_size_before, before_size);
                file_size_reduction_bytes += before_size - after_size;
                trigger_latency_ns = @max(trigger_latency_ns, elapsed_ns);
            }
        }
    }
    const write_end = std.time.nanoTimestamp();

    return .{
        .live_key_count = config.ops,
        .update_rounds = config.update_rounds,
        .value_size = config.value_size,
        .operation_count = operation_count,
        .write_time_ns = @intCast(write_end - write_start),
        .write_latency = summarizeLatencies(write_latencies),
        .compaction_triggered = compaction_triggered,
        .compaction_trigger_count = compaction_trigger_count,
        .waste_ratio_before = peak_waste_before,
        .waste_ratio_after = store.calculateMainFileWasteRatio(),
        .file_size_before = file_size_before,
        .file_size_after = store.file_size.load(.monotonic),
        .file_size_reduction_bytes = file_size_reduction_bytes,
        .trigger_latency_ns = trigger_latency_ns,
    };
}

fn runCompactionBenchmark(allocator: std.mem.Allocator, config: Config) !void {
    if (config.mode != .persisted) return error.CompactionRequiresPersistedMode;
    try requireTmpPath(config.db_path);

    var stdout = std.fs.File.stdout().deprecatedWriter().any();
    if (config.fresh) removeStoreArtifacts(allocator, config.db_path);
    defer if (config.fresh) removeStoreArtifacts(allocator, config.db_path);

    var store = try phage.Phage.init(allocator, config.db_path);
    defer store.deinit();

    const stats = try runCompactionWorkload(allocator, &store, config);
    switch (config.output_format) {
        .human => try printCompactionBenchmarkStats(stats, &stdout),
        .json => try printCompactionBenchmarkJson(config, stats, &stdout),
    }
}

fn runPersistedBenchmark(allocator: std.mem.Allocator, config: Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter().any();
    if (config.output_format == .human) {
        try stdout.print("Benchmarking...\n", .{});
        try stdout.print("Mode: persisted\n", .{});
        try stdout.print("Value size: {d} bytes\n", .{config.value_size});
        try stdout.print("Batch size: {d}\n", .{config.batch_size});
    }

    if (config.fresh) {
        removeIfExists(config.db_path);
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{config.db_path});
        defer allocator.free(wal_path);
        removeIfExists(wal_path);
    }

    var store = try phage.Phage.init(allocator, config.db_path);
    defer store.deinit();

    const stats = try runBenchmark(&store, .{ .ops = config.ops, .value_size = config.value_size, .batch_size = config.batch_size, .read_api = config.read_api });
    switch (config.output_format) {
        .human => {
            try printBenchmarkStats(config, stats, &stdout);
            try stdout.print("Benchmark completed.\n", .{});
        },
        .json => try printBenchmarkJson(config, stats, &stdout),
    }
}

fn runMemoryBenchmark(allocator: std.mem.Allocator, config: Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter().any();
    if (config.output_format == .human) {
        try stdout.print("Benchmarking...\n", .{});
        try stdout.print("Mode: memory\n", .{});
        try stdout.print("Value size: {d} bytes\n", .{config.value_size});
        try stdout.print("Batch size: {d}\n", .{config.batch_size});
    }

    var store = MemoryBenchmarkStore.init(allocator);
    defer store.deinit();

    const stats = try runBenchmark(&store, .{ .ops = config.ops, .value_size = config.value_size, .batch_size = config.batch_size, .read_api = config.read_api });
    switch (config.output_format) {
        .human => {
            try printBenchmarkStats(config, stats, &stdout);
            try stdout.print("Benchmark completed.\n", .{});
        },
        .json => try printBenchmarkJson(config, stats, &stdout),
    }
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

    switch (config.workload_profile) {
        .standard => switch (config.mode) {
            .persisted => try runPersistedBenchmark(allocator, config),
            .memory => try runMemoryBenchmark(allocator, config),
        },
        .compaction => try runCompactionBenchmark(allocator, config),
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

test "benchmark args support configurable batch size" {
    var config = try parseArgSlice(std.testing.allocator, &.{ "phage-benchmark", "7", "--batch-size", "4" });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), config.ops);
    try std.testing.expectEqual(@as(usize, 4), config.batch_size);
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

        fn putBatch(self: *@This(), pairs: []const phage.Phage.BatchPair) !void {
            for (pairs) |pair| {
                try self.put(pair.key, pair.value);
            }
        }

        fn get(self: *@This(), key: []const u8) ![]u8 {
            _ = key;
            return try self.allocator.alloc(u8, self.expected_value_size);
        }

        fn getInto(self: *@This(), key: []const u8, buffer: []u8) ![]u8 {
            _ = key;
            try std.testing.expect(buffer.len >= self.expected_value_size);
            @memset(buffer[0..self.expected_value_size], 'v');
            return buffer[0..self.expected_value_size];
        }
    };

    var store = FakeStore{ .allocator = std.testing.allocator, .expected_value_size = 128 };
    const stats = try runBenchmark(&store, .{ .ops = 3, .value_size = 128 });

    try std.testing.expectEqual(@as(usize, 3), store.puts);
    try std.testing.expectEqual(@as(u32, 3), stats.num_ops);
}

test "benchmark runner groups writes by configured batch size" {
    const FakeStore = struct {
        allocator: std.mem.Allocator,
        batch_calls: usize = 0,
        put_calls: usize = 0,
        total_pairs: usize = 0,
        max_batch_len: usize = 0,

        fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            _ = key;
            _ = value;
            self.put_calls += 1;
        }

        fn putBatch(self: *@This(), pairs: []const phage.Phage.BatchPair) !void {
            self.batch_calls += 1;
            self.total_pairs += pairs.len;
            self.max_batch_len = @max(self.max_batch_len, pairs.len);
        }

        fn get(self: *@This(), key: []const u8) ![]u8 {
            _ = key;
            return try self.allocator.dupe(u8, "value");
        }

        fn getInto(self: *@This(), key: []const u8, buffer: []u8) ![]u8 {
            _ = self;
            _ = key;
            @memcpy(buffer[0..5], "value");
            return buffer[0..5];
        }
    };

    var store = FakeStore{ .allocator = std.testing.allocator };
    const stats = try runBenchmark(&store, .{ .ops = 5, .value_size = 16, .batch_size = 2 });

    try std.testing.expectEqual(@as(u32, 5), stats.num_ops);
    try std.testing.expectEqual(@as(usize, 0), store.put_calls);
    try std.testing.expectEqual(@as(usize, 3), store.batch_calls);
    try std.testing.expectEqual(@as(usize, 5), store.total_pairs);
    try std.testing.expectEqual(@as(usize, 2), store.max_batch_len);
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

    try printBenchmarkStats(.{ .ops = 3, .read_api = .get }, stats, &writer);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Read API: get") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Write latency p50/p95/p99") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Read latency p50/p95/p99") != null);
}

test "benchmark args support compaction workload profile" {
    var config = try parseArgSlice(std.testing.allocator, &.{ "phage-benchmark", "128", "--profile", "compaction", "--update-rounds", "2", "--db-path", "/tmp/phage-compaction-test" });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(WorkloadProfile.compaction, config.workload_profile);
    try std.testing.expectEqual(@as(u32, 128), config.ops);
    try std.testing.expectEqual(@as(u32, 2), config.update_rounds);
    try std.testing.expectEqualStrings("/tmp/phage-compaction-test", config.db_path);
}

test "compaction benchmark json output names profile and compaction metrics" {
    const stats = CompactionBenchmarkStats{
        .live_key_count = 128,
        .update_rounds = 2,
        .value_size = 64,
        .operation_count = 384,
        .write_time_ns = 12000,
        .write_latency = .{ .p50_ns = 1000, .p95_ns = 2000, .p99_ns = 3000 },
        .compaction_triggered = true,
        .compaction_trigger_count = 2,
        .waste_ratio_before = 0.49,
        .waste_ratio_after = 0.0,
        .file_size_before = 20480,
        .file_size_after = 10240,
        .file_size_reduction_bytes = 10240,
        .trigger_latency_ns = 25000,
    };

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try printCompactionBenchmarkJson(.{ .ops = 128, .value_size = 64, .batch_size = 1, .read_api = .get_into, .workload_profile = .compaction, .update_rounds = 2 }, stats, &writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("compaction", root.get("workload_profile").?.string);
    try std.testing.expectEqualStrings("persisted", root.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 384), root.get("operation_count").?.integer);
    try std.testing.expectEqual(@as(i64, 128), root.get("live_key_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), root.get("update_rounds").?.integer);
    try std.testing.expect(root.get("backend_status") != null);
    try std.testing.expect(root.get("throughput").?.object.get("write_ops_per_sec") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("write").?.object.get("p95") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("trigger") != null);
    const compaction = root.get("compaction").?.object;
    try std.testing.expect(compaction.get("triggered").?.bool);
    try std.testing.expectEqual(@as(i64, 2), compaction.get("trigger_count").?.integer);
    try std.testing.expectEqual(@as(i64, 10240), compaction.get("file_size_reduction_bytes").?.integer);
}

test "benchmark args support json output" {
    var config = try parseArgSlice(std.testing.allocator, &.{ "phage-benchmark", "7", "--json" });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(OutputFormat.json, config.output_format);
}

test "benchmark args support buffered read API mode" {
    var config = try parseArgSlice(std.testing.allocator, &.{ "phage-benchmark", "7", "--read-api", "get-into" });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(ReadApi.get_into, config.read_api);
}

test "benchmark json output labels the measured read API" {
    const stats = BenchmarkStats{
        .num_ops = 3,
        .write_time_ns = 3000,
        .read_time_ns = 6000,
        .total_time_ns = 9000,
        .write_latency = .{ .p50_ns = 1000, .p95_ns = 2000, .p99_ns = 3000 },
        .read_latency = .{ .p50_ns = 4000, .p95_ns = 5000, .p99_ns = 6000 },
    };
    const config = Config{
        .ops = 3,
        .value_size = 16,
        .batch_size = 2,
        .mode = .memory,
        .output_format = .json,
        .read_api = .get_into,
    };

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try printBenchmarkJson(config, stats, &writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("getInto", parsed.value.object.get("read_api").?.string);
}

test "benchmark runner can use one reusable read buffer" {
    const FakeStore = struct {
        allocator: std.mem.Allocator,
        get_calls: usize = 0,
        get_into_calls: usize = 0,
        first_buffer_ptr: ?[*]u8 = null,
        reused_buffer: bool = true,

        fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            _ = self;
            _ = key;
            _ = value;
        }

        fn putBatch(self: *@This(), pairs: []const phage.Phage.BatchPair) !void {
            for (pairs) |pair| {
                try self.put(pair.key, pair.value);
            }
        }

        fn get(self: *@This(), key: []const u8) ![]u8 {
            _ = key;
            self.get_calls += 1;
            return try self.allocator.dupe(u8, "value-16-bytes!!");
        }

        fn getInto(self: *@This(), key: []const u8, buffer: []u8) ![]u8 {
            _ = key;
            self.get_into_calls += 1;
            if (self.first_buffer_ptr) |ptr| {
                self.reused_buffer = self.reused_buffer and ptr == buffer.ptr;
            } else {
                self.first_buffer_ptr = buffer.ptr;
            }
            @memset(buffer[0..16], 'r');
            return buffer[0..16];
        }
    };

    var store = FakeStore{ .allocator = std.testing.allocator };
    const stats = try runBenchmark(&store, .{ .ops = 3, .value_size = 16, .read_api = .get_into });

    try std.testing.expectEqual(@as(u32, 3), stats.num_ops);
    try std.testing.expectEqual(@as(usize, 0), store.get_calls);
    try std.testing.expectEqual(@as(usize, 3), store.get_into_calls);
    try std.testing.expect(store.reused_buffer);
}

test "benchmark json output is parseable and includes reproducibility fields" {
    const stats = BenchmarkStats{
        .num_ops = 3,
        .write_time_ns = 3000,
        .read_time_ns = 6000,
        .total_time_ns = 9000,
        .write_latency = .{ .p50_ns = 1000, .p95_ns = 2000, .p99_ns = 3000 },
        .read_latency = .{ .p50_ns = 4000, .p95_ns = 5000, .p99_ns = 6000 },
    };
    const config = Config{
        .ops = 3,
        .value_size = 16,
        .batch_size = 2,
        .mode = .memory,
        .output_format = .json,
    };

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try printBenchmarkJson(config, stats, &writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("memory", root.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 3), root.get("operation_count").?.integer);
    try std.testing.expectEqual(@as(i64, 16), root.get("value_size").?.integer);
    try std.testing.expectEqual(@as(i64, 2), root.get("batch_size").?.integer);
    try std.testing.expect(root.get("throughput").?.object.get("total_ops_per_sec") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("write").?.object.get("p50") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("write").?.object.get("p95") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("write").?.object.get("p99") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("read").?.object.get("p50") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("read").?.object.get("p95") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("read").?.object.get("p99") != null);
}
