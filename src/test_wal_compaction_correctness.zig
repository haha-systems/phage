const std = @import("std");

const phage = @import("root.zig");
const index = @import("index.zig");
const Wal = @import("io/wal.zig").Wal;

const Phage = phage.Phage;

const compaction_test_dir = ".zig-cache/phage-tests";
const compaction_test_path = compaction_test_dir ++ "/compaction_correctness.db";
const compaction_wal_boundary_path = compaction_test_dir ++ "/compaction_wal_boundary.db";

test "wal_compaction: repeated updates compact to latest readable index entries" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath(compaction_test_dir);
    cleanupPath(compaction_test_path);
    defer cleanupPath(compaction_test_path);

    var store = try Phage.init(allocator, compaction_test_path);
    defer store.deinit();

    store.compaction_threshold = 2.0;
    try store.put("alpha", "alpha-v0");
    try store.put("beta", "beta-v0");
    try store.put("gamma", "gamma-v0");

    for (1..8) |i| {
        const alpha_value = try std.fmt.allocPrint(allocator, "alpha-v{d}", .{i});
        defer allocator.free(alpha_value);
        const beta_value = try std.fmt.allocPrint(allocator, "beta-v{d}", .{i});
        defer allocator.free(beta_value);
        const gamma_value = try std.fmt.allocPrint(allocator, "gamma-v{d}", .{i});
        defer allocator.free(gamma_value);

        try store.put("alpha", alpha_value);
        try store.put("beta", beta_value);
        try store.put("gamma", gamma_value);
    }

    const waste_before = store.calculateMainFileWasteRatio();
    try std.testing.expect(waste_before > 0.5);

    const alpha_stale_offset = store.index.get("alpha").?.offset;
    const beta_stale_offset = store.index.get("beta").?.offset;
    const gamma_stale_offset = store.index.get("gamma").?.offset;

    store.compaction_threshold = 0.01;
    try store.put("alpha", "alpha-final");

    try expectIndexEntryReadsValue(&store, "alpha", "alpha-final");
    try expectIndexEntryReadsValue(&store, "beta", "beta-v7");
    try expectIndexEntryReadsValue(&store, "gamma", "gamma-v7");

    const compacted_file_size = store.file_size.load(.monotonic);
    try std.testing.expect(store.index.get("alpha").?.offset < compacted_file_size);
    try std.testing.expect(store.index.get("beta").?.offset < compacted_file_size);
    try std.testing.expect(store.index.get("gamma").?.offset < compacted_file_size);
    try std.testing.expect(
        store.index.get("alpha").?.offset != alpha_stale_offset or
            store.index.get("beta").?.offset != beta_stale_offset or
            store.index.get("gamma").?.offset != gamma_stale_offset,
    );

    const waste_after = store.calculateMainFileWasteRatio();
    try std.testing.expect(waste_after < waste_before);
}

test "wal_compaction: recovery replays WAL delete after compacted index rebuild" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath(compaction_test_dir);
    cleanupPath(compaction_wal_boundary_path);
    defer cleanupPath(compaction_wal_boundary_path);

    {
        var store = try Phage.init(allocator, compaction_wal_boundary_path);
        defer store.deinit();

        try createCompactedStore(&store, allocator);
        try expectIndexEntryReadsValue(&store, "survivor", "survivor-v5");
        try expectIndexEntryReadsValue(&store, "obsolete", "obsolete-v5");

        try appendDeleteWalEntry(&store, "obsolete");
        const wal_stat = try std.posix.fstat(store.wal_fd);
        try std.testing.expect(wal_stat.size > 0);
    }

    {
        var recovered = try Phage.init(allocator, compaction_wal_boundary_path);
        defer recovered.deinit();

        try std.testing.expectError(error.KeyNotFound, recovered.get("obsolete"));
        try expectIndexEntryReadsValue(&recovered, "survivor", "survivor-v5");

        const wal_stat = try std.posix.fstat(recovered.wal_fd);
        try std.testing.expectEqual(@as(i64, 0), wal_stat.size);
    }
}

fn createCompactedStore(store: *Phage, allocator: std.mem.Allocator) !void {
    store.compaction_threshold = 2.0;
    try store.put("survivor", "survivor-v0");
    try store.put("obsolete", "obsolete-v0");

    for (1..6) |i| {
        const survivor_value = try std.fmt.allocPrint(allocator, "survivor-v{d}", .{i});
        defer allocator.free(survivor_value);
        const obsolete_value = try std.fmt.allocPrint(allocator, "obsolete-v{d}", .{i});
        defer allocator.free(obsolete_value);

        try store.put("survivor", survivor_value);
        try store.put("obsolete", obsolete_value);
    }

    try std.testing.expect(store.calculateMainFileWasteRatio() > 0.4);
    store.compaction_threshold = 0.01;
    try store.put("compaction-boundary-trigger", "trigger-value");
    try std.testing.expect(store.calculateMainFileWasteRatio() < 0.4);
}

fn expectIndexEntryReadsValue(store: *Phage, key: []const u8, expected_value: []const u8) !void {
    const entry = store.index.get(key) orelse return error.KeyNotFound;
    const header_size = @sizeOf(index.EntryHeader);
    const total_len = header_size + key.len + expected_value.len;
    try std.testing.expectEqual(total_len, entry.len);

    const buffer = try store.allocator.alloc(u8, entry.len);
    defer store.allocator.free(buffer);
    const bytes_read = try std.posix.pread(store.fd, buffer, entry.offset);
    try std.testing.expectEqual(entry.len, bytes_read);

    const header = std.mem.bytesToValue(index.EntryHeader, buffer[0..header_size]);
    try std.testing.expectEqual(key.len, header.key_len);
    try std.testing.expectEqual(expected_value.len, header.val_len);

    const stored_key = buffer[header_size..][0..header.key_len];
    try std.testing.expectEqualStrings(key, stored_key);

    const stored_value = buffer[header_size + header.key_len ..][0..header.val_len];
    try std.testing.expectEqualStrings(expected_value, stored_value);
}

fn appendDeleteWalEntry(store: *Phage, key: []const u8) !void {
    const header = Wal.WalEntryHeader{
        .op_type = .delete,
        .key_len = key.len,
        .val_len = 0,
        .offset = 0,
        .checksum = Wal.calculateChecksum(.delete, @intCast(key.len), 0, 0, key),
        .padding = 0,
    };

    _ = try std.posix.pwrite(store.wal_fd, std.mem.asBytes(&header), 0);
    _ = try std.posix.pwrite(store.wal_fd, key, @sizeOf(Wal.WalEntryHeader));
    try std.posix.fsync(store.wal_fd);
}

fn cleanupPath(path: []const u8) void {
    std.posix.unlink(path) catch {};

    var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path}) catch return;
    std.posix.unlink(wal_path) catch {};

    var compact_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = std.fmt.bufPrint(&compact_path_buf, "{s}.compact.tmp", .{path}) catch return;
    std.posix.unlink(compact_path) catch {};
}
