//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");

const lib = @import("root.zig");
const Phage = lib.Phage;
const log = std.log.scoped(.phage_demon);
pub const log_level: std.log.Level = .info;

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

test "reading and writing keys" {
    const allocator = std.testing.allocator;
    const test_file = "phage_test.db";

    // Force clean start
    std.posix.unlink(test_file) catch {};

    var store = blk: {
        const s = Phage.init(allocator, test_file, .{ .use_sqpoll = false }) catch |err| {
            log.err("INIT FAILED: {s}", .{@errorName(err)});
            return err;
        };
        break :blk s;
    };

    defer {
        store.deinit() catch |err| {
            log.err("DEINIT FAILED: {s}", .{@errorName(err)});
        };
    }

    try store.put("key1", "value1");

    {
        const val1 = try store.get("key1", allocator);
        defer allocator.free(val1);
        try std.testing.expectEqualStrings("value1", val1);
        log.info("Key1 verified", .{});
    }
}

pub fn main() !void {
    const child_ally = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator{ .child_allocator = child_ally, .state = .{} };
    const allocator = arena.allocator();

    const test_file = "phage_bench.db";
    std.posix.unlink(test_file) catch {};

    var store = try Phage.init(allocator, test_file, .{ .use_sqpoll = false });
    const numOps: usize = 1000; // number of operations to benchmark

    // Benchmark writes.
    const startWrite: usize = @intCast(std.time.nanoTimestamp());
    for (0..numOps) |i| {
        // Create unique keys/values for each operation.
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        try store.put(key, value);
    }
    const mid: usize = @intCast(std.time.nanoTimestamp());

    // Benchmark reads.
    for (0..numOps) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        // Get returns a duplicated buffer that we must free.
        _ = try store.get(key, allocator);
    }
    const end: usize = @intCast(std.time.nanoTimestamp());

    try store.deinit();
    arena.deinit();

    // calculate write time in milliseconds
    const writeTime = (mid - startWrite) / 1_000_000;

    // calculate read time in milliseconds
    const readTime = (end - mid) / 1_000_000;

    log.info("=== Benchmark Results ===", .{});
    log.info("Write time: {d} ms for {d} writes", .{ writeTime, numOps });
    log.info("Read time: {d} ms for {d} reads", .{ readTime, numOps });

    log.info("=== Benchmark Completed ===", .{});
    std.posix.unlink(test_file) catch {};
    log.info("=== All Tests Passed ===", .{});
}

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
