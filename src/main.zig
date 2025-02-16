//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("phage");
const Phage = lib.Phage;
const log = std.log.scoped(.phage_demon);
pub const log_level: std.log.Level = .info;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const test_file = "phage_bench.db";
    std.posix.unlink(test_file) catch {};

    var store = try Phage.init(allocator, test_file);
    defer store.deinit();

    const numOps: usize = 10_000; // number of operations to benchmark

    // Benchmark writes.
    const startWrite: usize = @intCast(std.time.milliTimestamp());
    for (0..numOps) |i| {
        // Create unique keys/values for each operation.
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        try store.put(key, value);
        allocator.free(key);
        allocator.free(value);
    }
    const mid: usize = @intCast(std.time.milliTimestamp());

    // Benchmark reads.
    for (0..numOps) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        // Get returns a duplicated buffer that we must free.
        const value = try store.get(key, allocator);
        allocator.free(key);
        allocator.free(value);
    }
    const end: usize = @intCast(std.time.milliTimestamp());

    std.debug.print("Performed {d} writes in {d} ms (~{d} ops/ms)\n", .{ numOps, mid - startWrite, numOps / (mid - startWrite) });
    std.debug.print("Performed {d} reads in {d} ms (~{d} ops/ms)\n", .{ numOps, end - mid, numOps / (end - mid) });
}

// pub fn main() !void {
//     // Initialize logging
//     log.info("\n\n=== Starting Phage Tests ===\n", .{});

//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();

//     const test_file = "phage_test.db";
//     defer std.posix.unlink(test_file) catch {};

//     // Force clean start
//     std.posix.unlink(test_file) catch {};

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

//     log.info("Test phase 2: Writes", .{});
//     try store.put("key1", "value1");

//     log.info("Test phase 3: Verification", .{});
//     const val = try store.get("key1", allocator);
//     defer allocator.free(val);
//     try std.testing.expectEqualStrings("value1", val);

//     log.info("=== All Tests Passed ===", .{});
// }
