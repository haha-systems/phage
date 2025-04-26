//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");

const lib = @import("root.zig");
const Phage = lib.Phage;
const log = std.log.scoped(.phage_demon);
pub const log_level: std.log.Level = .info;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const db_path = "phage.db";
    var store = try Phage.init(allocator, db_path);
    defer store.deinit();

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    try stdout.print("phage v0.1 :: type 'help' for commands, 'exit' to exit\n", .{});
    try stdout.print("phage > ", .{});

    while (true) {
        const input = blk: {
            if (try stdin.readUntilDelimiterOrEof(buffer, '\n')) |line| {
                break :blk std.mem.trimRight(u8, line, "\r\n");
            } else {
                try stderr.print("Error reading input\n", .{});
                break :blk null;
            }
        };

        try executeCommand(&store, allocator, input.?, stdout);
        try stdout.print("phage > ", .{});
    }

    try stdout.print("\nBye!\n", .{});
}

fn executeCommand(store: *Phage, allocator: std.mem.Allocator, input: []const u8, writer: anytype) !void {
    var tokens = std.mem.splitSequence(u8, std.mem.trim(u8, input, " "), " ");
    if (tokens.buffer.len == 0) {
        return;
    }
    const cmd = tokens.next() orelse return;

    if (std.ascii.eqlIgnoreCase(cmd, "help")) {
        try writer.print(
            \\Available commands (case insensitive):
            \\  PUT <key> <value> - Store a key-value pair
            \\  GET <key>         - Retrieve a value by key
            \\  DELETE <key>      - Delete a key-value pair
            \\  EXIT              - Quit the CLI
            \\  HELP              - Show this help
            \\
        , .{});
    } else if (std.ascii.eqlIgnoreCase(cmd, "exit")) {
        std.posix.exit(0);
    } else if (std.ascii.eqlIgnoreCase(cmd, "put")) {
        const key = tokens.next() orelse return try writer.print("Error: Missing key\n", .{});
        const value = tokens.next() orelse return try writer.print("Error: Missing value\n", .{});
        if (tokens.next() != null) return try writer.print("Error: Too many arguments\n", .{});

        store.put(key, value) catch |err| {
            try writer.print("Error: Failed to put key '{s}': {s}\n", .{ key, @errorName(err) });
            return;
        };
        try writer.print("OK\n", .{});
    } else if (std.ascii.eqlIgnoreCase(cmd, "get")) {
        const key = tokens.next() orelse return try writer.print("Error: Missing key\n", .{});
        if (tokens.next() != null) return try writer.print("Error: Too many arguments\n", .{});

        const value = store.get(key) catch |err| {
            try writer.print("Error: Failed to get key '{s}': {s}\n", .{ key, @errorName(err) });
            return;
        };
        defer allocator.free(value);
        try writer.print("\"{s}\"\n", .{value});
    } else if (std.ascii.eqlIgnoreCase(cmd, "delete")) {
        const key = tokens.next() orelse return try writer.print("Error: Missing key\n", .{});
        if (tokens.next() != null) return try writer.print("Error: Too many arguments\n", .{});

        _ = store.delete(key) catch |err| {
            try writer.print("Error: Failed to delete key '{s}': {s}\n", .{ key, @errorName(err) });
            return;
        };

        try writer.print("OK\n", .{});
    } else if (std.ascii.eqlIgnoreCase(cmd, "keys")) {
        var pattern = tokens.next() orelse {
            try writer.print("Error: Missing pattern\n", .{});
            return;
        };

        if (tokens.next() != null) {
            try writer.print("Error: Too many arguments\n", .{});
            return;
        }

        // TODO: allow for a single * character wildcard
        const wildcard_pattern = std.mem.eql(u8, pattern, "*");
        if (wildcard_pattern) {
            pattern = ".*";
        }

        try store.printKeys(pattern, writer);
    } else {
        try writer.print("Error: Unknown command '{s}'. Type HELP for commands.\n", .{cmd});
    }
}
// pub fn main() !void {
//     const child_ally = std.heap.page_allocator;
//     var arena = std.heap.ArenaAllocator{ .child_allocator = child_ally, .state = .{} };
//     const allocator = arena.allocator();

//     const test_file = "phage.db";
//     const wal_file = "phage.wal";
//     std.posix.unlink(test_file) catch {};
//     std.posix.unlink(wal_file) catch {};

//     var store = try Phage.init(allocator, test_file, wal_file, .{ .use_sqpoll = false });
//     const numOps: usize = 1; // number of operations to benchmark

//     // Benchmark writes.
//     const startWrite: usize = @intCast(std.time.nanoTimestamp());
//     for (0..numOps) |i| {
//         // Create unique keys/values for each operation.
//         const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
//         const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
//         try store.put(key, value);
//     }
//     const mid: usize = @intCast(std.time.nanoTimestamp());

//     // Benchmark reads.
//     for (0..numOps) |i| {
//         const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
//         // Get returns a duplicated buffer that we must free.
//         _ = try store.get(key, allocator);
//     }
//     const end: usize = @intCast(std.time.nanoTimestamp());

//     try store.deinit();
//     arena.deinit();

//     // calculate write time in milliseconds
//     const writeTime = (mid - startWrite) / 1_000_000;

//     // calculate read time in milliseconds
//     const readTime = (end - mid) / 1_000_000;

//     log.info("=== Benchmark Results ===", .{});
//     log.info("Write time: {d} ms for {d} writes", .{ writeTime, numOps });
//     log.info("Read time: {d} ms for {d} reads", .{ readTime, numOps });

//     log.info("=== Benchmark Completed ===", .{});
//     std.posix.unlink(test_file) catch {};
//     log.info("=== All Tests Passed ===", .{});
// }

// pub fn main() !void {
//     // Initialize logging
//     log.info("\n\n=== Starting Phage Tests ===\n", .{});

//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();

//     const test_file = "phage_test.db";
//     // Force clean start
//     std.posix.unlink(test_file) catch {};

//     log.info("Test phase 1: Initialization", .{});
//     var store = blk: {
//         const s = Phage.init(allocator, test_file, .{ .use_sqpoll = false }) catch |err| {
//             std.log.err("INIT FAILED: {s}", .{@errorName(err)});
//             return err;
//         };
//         break :blk s;
//     };
//     defer {
//         log.info("Cleaning up", .{});
//         store.deinit() catch |err| {
//             std.log.err("DEINIT FAILED: {s}", .{@errorName(err)});
//         };
//     }

//     log.info("Test phase 2: Writes", .{});
//     try store.put("key1", "value1");

//     log.info("Test phase 3: Reads", .{});
//     {
//         const val1 = try store.get("key1", allocator);
//         defer allocator.free(val1);
//         try std.testing.expectEqualStrings("value1", val1);
//         log.info("Key1 verified", .{});
//     }

//     log.info("=== All Tests Passed ===", .{});
// }

// pub fn main() !void {
//     // Initialize logging
//     log.info("\n\n=== Starting Phage Tests ===\n", .{});
//
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     const test_file = "phage_test.db";
//     defer std.posix.unlink(test_file) catch {};
//
//     // Force clean start
//     std.posix.unlink(test_file) catch {};
//
//     log.info("Test phase 1: Initialization", .{});
//     var store = blk: {
//         const s = Phage.init(allocator, test_file) catch |err| {
//             std.log.err("INIT FAILED: {s}", .{@errorName(err)});
//             return err;
//         };
//         break :blk s;
//     };
//     defer {
//         log.info("Test phase 4: Cleanup", .{});
//         store.deinit();
//     }
//
//     log.info("Test phase 2: Writes", .{});
//     try store.put("key1", "value1");
//
//     log.info("Test phase 3: Verification", .{});
//     const val = try store.get("key1", allocator);
//     defer allocator.free(val);
//     try std.testing.expectEqualStrings("value1", val);
//
//     log.info("=== All Tests Passed ===", .{});
// }
