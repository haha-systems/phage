const std = @import("std");
const Phage = @import("../src/root.zig").Phage;

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    var store = try Phage.init(allocator, "test_phase1.db");
    defer store.deinit();

    std.debug.print("Initial WAL size: {}\n", .{store.wal_file_size.load(.monotonic)});

    // Test 1: Single put
    try store.put("key1", "value1");
    std.debug.print("After put 1 - WAL size: {}\n", .{store.wal_file_size.load(.monotonic)});

    // Test 2: Duplicate key
    try store.put("key1", "value2");
    std.debug.print("After put 2 - WAL size: {}\n", .{store.wal_file_size.load(.monotonic)});

    // Test 3: Get latest value
    const value = try store.get("key1");
    defer allocator.free(value);
    std.debug.print("Retrieved value: {s}\n", .{value});

    // Test 4: Check file sizes
    const wal_stat = try std.posix.fstat(store.wal_fd);
    const main_stat = try std.posix.fstat(store.fd);
    std.debug.print("WAL file actual size: {}\n", .{wal_stat.size});
    std.debug.print("Main file size: {}\n", .{main_stat.size});
    std.debug.print("WAL tracked size: {}\n", .{store.wal_file_size.load(.monotonic)});

    // Cleanup
    std.posix.unlink("test_phase1.db") catch {};
    std.posix.unlink("test_phase1.db.wal") catch {};
}
