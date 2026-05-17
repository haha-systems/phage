const std = @import("std");
const Phage = @import("phage").Phage;
const log = @import("colored_logger").myLogFn;

const NANOSECONDS_PER_SECOND: f64 = 1_000_000_000.0;
const NANOSECONDS_PER_MILLISECOND: u64 = 1_000_000;

pub const BenchmarkStats = struct {
    num_ops: u32,
    write_time_ns: u64,
    read_time_ns: u64,
    total_time_ns: u64,

    pub fn writeOpsPerSec(self: BenchmarkStats) f64 {
        return opsPerSec(self.num_ops, self.write_time_ns);
    }

    pub fn readOpsPerSec(self: BenchmarkStats) f64 {
        return opsPerSec(self.num_ops, self.read_time_ns);
    }

    pub fn totalOpsPerSec(self: BenchmarkStats) f64 {
        return opsPerSec(@as(u64, self.num_ops) * 2, self.total_time_ns);
    }

    fn opsPerSec(num_ops: u64, elapsed_ns: u64) f64 {
        if (num_ops == 0 or elapsed_ns == 0) return 0.0;
        return @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / NANOSECONDS_PER_SECOND);
    }
};

pub const Command = enum {
    put,
    get,
    delete,
    keys,
    restore_index,
    restore_wal,
    benchmark,
    help,
    exit,
    unknown,
};

pub const CommandResult = struct {
    command: Command,
    key: []const u8,
    value: []const u8,
};

/// Parses a command string and returns true if the command is valid.
/// The command string is case insensitive.
pub fn validateCommand(cmd_string: []const u8) bool {
    // extract the first token from the command string, e.g. "PUT key value" -> "PUT"
    var tokens = std.mem.splitSequence(u8, std.mem.trim(u8, cmd_string, " "), " ");
    if (tokens.buffer.len == 0) {
        return false;
    }

    const cmd = tokens.next() orelse return false;
    const command = parseCommand(cmd);

    return switch (command) {
        Command.put, Command.get, Command.delete, Command.keys, Command.restore_index, Command.restore_wal, Command.benchmark, Command.help, Command.exit => true,
        Command.unknown => false,
    };
}

/// Parses a command string and returns the corresponding Command enum.
/// The command string is case insensitive.
/// If the command is not recognized, it returns Command.unknown.
/// The command string should be trimmed of leading and trailing whitespace.
/// The command string should be a single word, e.g. "PUT", "GET", "DELETE", etc.
pub fn parseCommand(cmd: []const u8) Command {
    if (std.ascii.eqlIgnoreCase(cmd, "put")) return Command.put;
    if (std.ascii.eqlIgnoreCase(cmd, "get")) return Command.get;
    if (std.ascii.eqlIgnoreCase(cmd, "delete") or std.ascii.eqlIgnoreCase(cmd, "del")) return Command.delete;
    if (std.ascii.eqlIgnoreCase(cmd, "keys")) return Command.keys;
    if (std.ascii.eqlIgnoreCase(cmd, "restore_index")) return Command.restore_index;
    if (std.ascii.eqlIgnoreCase(cmd, "restore_wal")) return Command.restore_wal;
    if (std.ascii.eqlIgnoreCase(cmd, "benchmark")) return Command.benchmark;
    if (std.ascii.eqlIgnoreCase(cmd, "help")) return Command.help;
    if (std.ascii.eqlIgnoreCase(cmd, "exit")) return Command.exit;
    return Command.unknown;
}

fn handlePut(store: *Phage, tokens: *std.mem.SplitIterator(u8, .sequence), writer: *std.io.AnyWriter) !void {
    const key = tokens.next() orelse return try writer.print("Error: Missing key\n", .{});
    const value = tokens.next() orelse return try writer.print("Error: Missing value\n", .{});
    if (tokens.next() != null) return try writer.print("Error: Too many arguments\n", .{});

    store.put(key, value) catch |err| {
        try writer.print("Error: Failed to put key '{s}': {s}\n", .{ key, @errorName(err) });
        return;
    };

    try writer.print("OK\n", .{});
    log(.debug, .demon, "Stored key-value pair: {s} = {s}", .{ key, value });
}

fn handleGet(store: *Phage, tokens: *std.mem.SplitIterator(u8, .sequence), writer: *std.io.AnyWriter, allocator: std.mem.Allocator) !void {
    const key = tokens.next() orelse return try writer.print("Error: Missing key\n", .{});
    if (tokens.next() != null) return try writer.print("Error: Too many arguments\n", .{});

    const value = store.get(key) catch |err| {
        try writer.print("Error: Failed to get key '{s}': {s}\n", .{ key, @errorName(err) });
        return;
    };
    defer allocator.free(value);

    try writer.print("\"{s}\"\n", .{value});
    log(.debug, .demon, "Retrieved key-value pair: {s} = {s}", .{ key, value });
}

fn handleDelete(store: *Phage, tokens: *std.mem.SplitIterator(u8, .sequence), writer: *std.io.AnyWriter) !void {
    const key = tokens.next() orelse return try writer.print("Error: Missing key\n", .{});
    if (tokens.next() != null) return try writer.print("Error: Too many arguments\n", .{});

    _ = store.delete(key) catch |err| {
        try writer.print("Error: Failed to delete key '{s}': {s}\n", .{ key, @errorName(err) });
        return;
    };

    try writer.print("OK\n", .{});
    log(.debug, .demon, "Deleted key: {s}", .{key});
}

fn handleKeys(store: *Phage, tokens: *std.mem.SplitIterator(u8, .sequence), writer: *std.io.AnyWriter) !void {
    var pattern = tokens.next() orelse {
        try writer.print("Error: Missing pattern.\n", .{});
        return;
    };

    if (tokens.next() != null) {
        try writer.print("Error: Too many arguments\n", .{});
        return;
    }

    // Trim leading and trailing whitespace
    pattern = std.mem.trim(u8, pattern, " \t\n\r");

    const wildcard_pattern = std.mem.eql(u8, pattern, "*");
    std.log.debug("Wildcard pattern: {}\n", .{wildcard_pattern});
    if (wildcard_pattern) {
        std.log.debug("Wildcard pattern detected: {s}\n", .{pattern});
        pattern = ".*";
    }

    std.log.debug("Pattern: {s}\n", .{pattern});

    const kvs = try store.findKeys(pattern) orelse {
        try writer.print("Error: Failed to find keys matching pattern '{s}'\n", .{pattern});
        return;
    };

    for (kvs) |key| {
        try writer.print("{s}\n", .{key});
    }

    try writer.print("OK\n", .{});
}

fn handleRestoreIndex(store: *Phage, writer: *std.io.AnyWriter) !void {
    try writer.print("Restoring index...\n", .{});
    store.restoreIndex() catch |err| {
        log(.err, .demon, "Failed to restore index: {s}", .{@errorName(err)});
        try writer.print("Error: Failed to restore index: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.print("Index restored successfully.\n", .{});
    log(.debug, .demon, "Restored index successfully. {d} key-values currently in index.", .{store.index.count()});
}

fn handleRestoreWAL(store: *Phage, writer: *std.io.AnyWriter) !void {
    try writer.print("Restoring WAL...\n", .{});
    store.restoreWAL() catch |err| {
        log(.err, .demon, "Failed to restore WAL: {s}", .{@errorName(err)});
        try writer.print("Error: Failed to restore WAL: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.print("WAL restored successfully.\n", .{});
    log(.debug, .demon, "Restored WAL successfully. {d} key-values currently in index.", .{store.index.count()});
}

fn runBenchmark(store: anytype, numOps: u32) !BenchmarkStats {
    const write_start = std.time.nanoTimestamp();
    for (0..numOps) |i| {
        const key = try std.fmt.allocPrint(store.allocator, "key{d}", .{i});
        defer store.allocator.free(key);

        const value = try std.fmt.allocPrint(store.allocator, "value{d}", .{i});
        defer store.allocator.free(value);

        try store.put(key, value);
    }
    const write_end = std.time.nanoTimestamp();

    const read_start = std.time.nanoTimestamp();
    for (0..numOps) |i| {
        const key = try std.fmt.allocPrint(store.allocator, "key{d}", .{i});
        defer store.allocator.free(key);

        const value = try store.get(key);
        defer store.allocator.free(value);
    }
    const read_end = std.time.nanoTimestamp();

    return .{
        .num_ops = numOps,
        .write_time_ns = @intCast(write_end - write_start),
        .read_time_ns = @intCast(read_end - read_start),
        .total_time_ns = @intCast(read_end - write_start),
    };
}

fn printBenchmarkStats(stats: BenchmarkStats, writer: *std.io.AnyWriter) !void {
    try writer.print("Write time: {d} ms\n", .{stats.write_time_ns / NANOSECONDS_PER_MILLISECOND});
    try writer.print("Read time: {d} ms\n", .{stats.read_time_ns / NANOSECONDS_PER_MILLISECOND});
    try writer.print("Total time: {d} ms\n", .{stats.total_time_ns / NANOSECONDS_PER_MILLISECOND});
    try writer.print("Write throughput: {d:.2} ops/sec\n", .{stats.writeOpsPerSec()});
    try writer.print("Read throughput: {d:.2} ops/sec\n", .{stats.readOpsPerSec()});
    try writer.print("Total throughput: {d:.2} ops/sec\n", .{stats.totalOpsPerSec()});
}

fn handleBenchmark(store: *Phage, numOps: []const u8, writer: *std.io.AnyWriter) !void {
    try writer.print("Benchmarking...\n", .{});

    const numOpsInt = std.fmt.parseInt(u32, numOps, 10) catch |err| {
        try writer.print("Error: Invalid number of operations: {s}\n", .{@errorName(err)});
        return;
    };

    const stats = runBenchmark(store, numOpsInt) catch |err| {
        try writer.print("Error: Benchmark failed: {s}\n", .{@errorName(err)});
        return;
    };

    try printBenchmarkStats(stats, writer);
    log(.debug, .demon, "Benchmark completed. Write throughput: {d:.2} ops/sec, Read throughput: {d:.2} ops/sec", .{ stats.writeOpsPerSec(), stats.readOpsPerSec() });
    try writer.print("Benchmark completed.\n", .{});
}

fn handleHelp(writer: *std.io.AnyWriter) !void {
    try writer.print(
        \\Available commands (case insensitive):
        \\  PUT <key> <value>  - Store a key-value pair
        \\  GET <key>          - Retrieve a value by key
        \\  DELETE <key>       - Delete a key-value pair
        \\  KEYS <pattern>     - List keys matching a regex pattern
        \\  RESTORE_INDEX      - Restore the index from the database
        \\  RESTORE_WAL        - Restore the database from the WAL\
        \\  BENCHMARK <numOps> - Benchmark the store with the given number of operations. WARNING: This will currently insert <numOps> key-values!
        \\  EXIT               - Quit the CLI
        \\  HELP               - Show this help
        \\
    , .{});
}

fn handleExit() !void {
    std.posix.exit(0);
}

fn handleUnknown(cmd: []const u8, writer: *std.io.AnyWriter) !void {
    try writer.print("Error: unknown command: {s}\n", .{cmd});
}

/// Executes a command on the Phage store sent by clients.
/// `input` should be a single line of input from the client, e.g. "PUT key value".
/// `writer` is a writer to send the response back to the client.
pub fn executeCommand(store: *Phage, allocator: std.mem.Allocator, input: []const u8) !void {
    var tokens = std.mem.splitSequence(u8, std.mem.trim(u8, input, " "), " ");
    if (tokens.buffer.len == 0) {
        return;
    }
    const cmd = tokens.next() orelse return error.InvalidCommand;

    var writer = std.io.getStdOut().writer().any();

    const command = parseCommand(cmd);
    std.log.debug("Command: {s}\n", .{cmd});
    std.log.debug("Command enum: {}\n", .{command});
    std.log.debug("Tokens: {s}\n", .{tokens.buffer});
    switch (command) {
        Command.put => try handlePut(store, &tokens, &writer),
        Command.get => try handleGet(store, &tokens, &writer, allocator),
        Command.delete => try handleDelete(store, &tokens, &writer),
        Command.keys => try handleKeys(store, &tokens, &writer),
        Command.restore_index => try handleRestoreIndex(store, &writer),
        Command.restore_wal => try handleRestoreWAL(store, &writer),
        Command.benchmark => try handleBenchmark(store, tokens.next().?, &writer),
        Command.help => try handleHelp(&writer),
        Command.exit => try handleExit(),
        Command.unknown => try handleUnknown(cmd, &writer),
    }
}

test "benchmark stats reports separate rates" {
    const stats = BenchmarkStats{
        .num_ops = 100,
        .write_time_ns = 100_000_000,
        .read_time_ns = 50_000_000,
        .total_time_ns = 150_000_000,
    };

    try std.testing.expectEqual(@as(f64, 1000.0), stats.writeOpsPerSec());
    try std.testing.expectEqual(@as(f64, 2000.0), stats.readOpsPerSec());
    try std.testing.expectApproxEqAbs(@as(f64, 1333.3333333333333), stats.totalOpsPerSec(), 0.000000000001);
}

test "benchmark runner writes then reads and frees values" {
    const FakeStore = struct {
        allocator: std.mem.Allocator,
        puts: usize = 0,
        gets: usize = 0,

        fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            _ = key;
            _ = value;
            self.puts += 1;
        }

        fn get(self: *@This(), key: []const u8) ![]u8 {
            _ = key;
            self.gets += 1;
            return try self.allocator.dupe(u8, "value");
        }
    };

    var store = FakeStore{ .allocator = std.testing.allocator };
    const stats = try runBenchmark(&store, 3);

    try std.testing.expectEqual(@as(usize, 3), store.puts);
    try std.testing.expectEqual(@as(usize, 3), store.gets);
    try std.testing.expectEqual(@as(u32, 3), stats.num_ops);
}
