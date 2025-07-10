const std = @import("std");
const Phage = @import("phage").Phage;
const log = @import("colored_logger").myLogFn;

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

fn handleBenchmark(store: *Phage, numOps: []const u8, writer: *std.io.AnyWriter) !void {
    try writer.print("Benchmarking...\n", .{});

    const numOpsInt = std.fmt.parseInt(u32, numOps, 10) catch |err| {
        try writer.print("Error: Invalid number of operations: {s}\n", .{@errorName(err)});
        return;
    };
    const startWrite: usize = @intCast(std.time.nanoTimestamp());

    for (0..numOpsInt) |i| {
        const key = try std.fmt.allocPrint(store.allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(store.allocator, "value{d}", .{i});
        store.put(key, value) catch |err| {
            try writer.print("Error: Failed to put key '{s}': {s}\n", .{ key, @errorName(err) });
            return;
        };
        _ = store.get(key) catch |err| {
            try writer.print("Error: Failed to get key '{s}': {s}\n", .{ key, @errorName(err) });
            return;
        };
        store.allocator.free(key);
        store.allocator.free(value);
    }
    const endWrite: usize = @intCast(std.time.nanoTimestamp());
    const elapsedTime: usize = endWrite - startWrite;
    const elapsedTimeSec: usize = elapsedTime / 1_000_000_000;
    const writeTime = (endWrite - startWrite) / 1_000_000;
    const readTime = (endWrite - startWrite) / 1_000_000;
    try writer.print("Write time: {d} ms\n", .{writeTime});
    try writer.print("Read time: {d} ms\n", .{readTime});
    try writer.print("Total time: {d} seconds\n", .{elapsedTimeSec});
    log(.debug, .demon, "Benchmark completed. Write time: {d} ms, Read time: {d} ms", .{ writeTime, readTime });
    log(.debug, .demon, "Total time: {d} seconds", .{elapsedTimeSec});
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
