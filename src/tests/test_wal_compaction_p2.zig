const std = @import("std");
const Phage = @import("src/root.zig").Phage;

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    var store = try Phage.init(allocator, "test_phase2.db");
    defer store.deinit();
    
    std.debug.print("=== Phase 2 Compaction Test ===\n", .{});
    
    // Test 1: Create some initial entries
    std.debug.print("\n1. Creating initial entries...\n", .{});
    try store.put("key1", "value1_original");
    try store.put("key2", "value2_original");
    try store.put("key3", "value3_original");
    
    var file_stat = try std.posix.fstat(store.fd);
    const initial_size = file_stat.size;
    std.debug.print("Initial file size: {} bytes\n", .{initial_size});
    std.debug.print("Initial waste ratio: {d:.2}%\n", .{store.calculateMainFileWasteRatio() * 100});
    
    // Test 2: Update the same keys multiple times to create waste
    std.debug.print("\n2. Creating waste by updating same keys...\n", .{});
    for (0..3) |i| {
        const value1 = try std.fmt.allocPrint(allocator, "value1_update_{d}", .{i});
        const value2 = try std.fmt.allocPrint(allocator, "value2_update_{d}", .{i});
        const value3 = try std.fmt.allocPrint(allocator, "value3_update_{d}", .{i});
        defer allocator.free(value1);
        defer allocator.free(value2);
        defer allocator.free(value3);
        
        try store.put("key1", value1);
        try store.put("key2", value2);
        try store.put("key3", value3);
        
        file_stat = try std.posix.fstat(store.fd);
        std.debug.print("After update {d}: file size = {} bytes, waste ratio = {d:.2}%\n", 
            .{ i, file_stat.size, store.calculateMainFileWasteRatio() * 100 });
    }
    
    // Test 3: Verify current values are correct
    std.debug.print("\n3. Verifying current values...\n", .{});
    const val1 = try store.get("key1");
    const val2 = try store.get("key2");
    const val3 = try store.get("key3");
    defer allocator.free(val1);
    defer allocator.free(val2);
    defer allocator.free(val3);
    
    std.debug.print("key1: {s}\n", .{val1});
    std.debug.print("key2: {s}\n", .{val2});
    std.debug.print("key3: {s}\n", .{val3});
    
    // Test 4: Trigger one more update to force compaction
    std.debug.print("\n4. Triggering compaction...\n", .{});
    const final_size_before = (try std.posix.fstat(store.fd)).size;
    const waste_before = store.calculateMainFileWasteRatio();
    
    try store.put("key1", "value1_final");
    
    const final_size_after = (try std.posix.fstat(store.fd)).size;
    const waste_after = store.calculateMainFileWasteRatio();
    
    std.debug.print("Before final put: file size = {} bytes, waste ratio = {d:.2}%\n", 
        .{ final_size_before, waste_before * 100 });
    std.debug.print("After final put: file size = {} bytes, waste ratio = {d:.2}%\n", 
        .{ final_size_after, waste_after * 100 });
    
    // Test 5: Verify data integrity after compaction
    std.debug.print("\n5. Verifying data integrity after compaction...\n", .{});
    const final_val1 = try store.get("key1");
    const final_val2 = try store.get("key2");
    const final_val3 = try store.get("key3");
    defer allocator.free(final_val1);
    defer allocator.free(final_val2);
    defer allocator.free(final_val3);
    
    std.debug.print("Final key1: {s}\n", .{final_val1});
    std.debug.print("Final key2: {s}\n", .{final_val2});
    std.debug.print("Final key3: {s}\n", .{final_val3});
    
    // Test 6: Verify compaction effectiveness
    const space_saved = @as(i64, @intCast(final_size_before)) - @as(i64, @intCast(final_size_after));
    if (space_saved > 0) {
        std.debug.print("\n✅ Compaction successful! Saved {} bytes ({d:.1}% reduction)\n", 
            .{ space_saved, @as(f64, @floatFromInt(space_saved)) / @as(f64, @floatFromInt(final_size_before)) * 100 });
    } else {
        std.debug.print("\n⚠️  Compaction may not have triggered or was not effective\n", .{});
    }
    
    // Cleanup
    std.posix.unlink("test_phase2.db") catch {};
    std.posix.unlink("test_phase2.db.wal") catch {};
    std.posix.unlink("test_phase2.db.compact.tmp") catch {};
    
    std.debug.print("\n=== Test Complete ===\n", .{});
}