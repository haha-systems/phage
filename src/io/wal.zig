// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");

// const log = @import("colored_logger").myLogFn;

const Phage = @import("../root.zig").Phage;
const IndexEntry = @import("../index.zig").IndexEntry;
const EntryHeader = @import("../index.zig").EntryHeader;

pub const Wal = struct {
    wal_path: []const u8,
    wal_fd: std.posix.fd_t = -1,
    wal_file_size: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, wal_path: []const u8) !Wal {
        const wal_fd = try std.posix.open(
            wal_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        if (wal_fd == -1) {
            return error.WalOpenError;
        }

        const wal_file_stat = try std.posix.fstat(wal_fd);
        const wal_file_size = std.atomic.Value(u64).init(@intCast(wal_file_stat.size));

        return Wal{
            .wal_path = wal_path,
            .wal_fd = wal_fd,
            .wal_file_size = wal_file_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Wal) void {
        _ = self;
    }

    // Ops begin from 1 to prevent confusion with zero-padding in the header
    pub const WalOperation = enum(u8) {
        put = 1,
        delete = 2,
    };

    pub const WalEntryHeader = packed struct {
        // The operation type (put/delete)
        op_type: WalOperation,
        // Length of the key
        key_len: usize,
        // Length of the value
        val_len: usize,
        // Offset in the main database file
        offset: usize,
        // Checksum for integrity verification
        checksum: u32,
        // Padding to ensure the size is 32 bytes
        padding: u24,

        comptime {
            if (@sizeOf(@This()) != 32) @compileError("invalid header size");
        }
    };

    const WalEntry = struct {
        header: WalEntryHeader,
        key: []const u8,
    };

    pub fn recover(store: *Phage) !void {
        // check the wal file size again as it may have changed
        // since the last time we checked
        const wal_file_stat = try std.posix.fstat(store.wal_fd);
        const wal_size: usize = @intCast(wal_file_stat.size);
        store.wal_file_size.store(wal_size, .release);

        // check if the wal file is empty with the new size
        if (wal_size == 0) {
            //log(.info, .phage, "WAL file is empty, nothing to recover", .{});
            return;
        }

        var offset: usize = 0;
        while (offset < wal_size) {
            //log(.debug, .phage, "Reading WAL entry at offset: {d}", .{offset});

            var header_buf: [@sizeOf(WalEntryHeader)]u8 = undefined;
            const header_read = try std.posix.pread(store.wal_fd, &header_buf, offset);
            if (header_read < @sizeOf(WalEntryHeader)) break;

            const header: WalEntryHeader = @bitCast(header_buf);
            const entry_len = std.math.add(usize, @sizeOf(WalEntryHeader), header.key_len) catch break;
            if (entry_len > wal_size - offset) break;

            const key_buf = try store.allocator.alloc(u8, header.key_len);
            defer store.allocator.free(key_buf);
            const key_read = try std.posix.pread(store.wal_fd, key_buf, offset + @sizeOf(WalEntryHeader));
            if (key_read < header.key_len) break;

            //log(.debug, .phage, "Read WAL entry: {s}", .{key_buf});
            //log(.debug, .phage, "Header: {s}", .{header_buf});

            if (calculateChecksum(header.op_type, @intCast(header.key_len), @intCast(header.val_len), header.offset, key_buf) != header.checksum) {
                //log(.err, .phage, "Checksum mismatch for WAL entry at offset: {d}", .{offset});
                //log(.err, .phage, "Expected checksum: {d}, computed checksum: {d}", .{ header.checksum, calculateChecksum(header.op_type, @intCast(header.key_len), @intCast(header.val_len), header.offset, key_buf) });
                //log(.err, .phage, "Key: {s}", .{key_buf});
                //log(.err, .phage, "Header: {s}", .{header_buf});
                break;
            }

            //log(.debug, .phage, "Checksum verified for offset: {d}", .{offset});
            //log(.debug, .phage, "Key length: {d}, Value length: {d}", .{ header.key_len, header.val_len });
            //log(.debug, .phage, "Offset: {d}", .{header.offset});
            //log(.debug, .phage, "Operation: {}", .{header.op_type});
            //log(.debug, .phage, "Checksum: {d}", .{header.checksum});

            switch (header.op_type) {
                .put => {
                    // We may have provisional entries in the WAL that haven't been written to the main file
                    // yet for whatever reason. If we find any, just skip them as we haven't guaranteed them yet.
                    if (header.offset == 0 and header.val_len == 0) {
                        //log(.info, .phage, "Skipping provisional entry for key: {s}", .{key_buf});
                        offset += @sizeOf(WalEntryHeader) + header.key_len;
                        continue;
                    }

                    try store.index.put(store.allocator, key_buf, .{
                        .offset = header.offset,
                        .len = @sizeOf(EntryHeader) + header.key_len + header.val_len,
                        .key_len = header.key_len,
                        .val_len = header.val_len,
                    });
                },
                .delete => {
                    const deleted = try store.index.delete(store.allocator, key_buf);
                    if (deleted) {
                        //log(.info, .phage, "Deleted entry for key: {s}", .{key_buf});
                    }
                },
            }

            offset += @sizeOf(WalEntryHeader) + header.key_len;
        }

        try clear(store);
    }

    pub fn clear(store: *Phage) !void {
        try std.posix.ftruncate(store.wal_fd, 0);
        try std.posix.lseek_SET(store.wal_fd, 0);
        try std.posix.fsync(store.wal_fd);

        // Make sure we reset the atomic file size to zero
        store.wal_file_size.store(0, .release);
    }

    pub fn calculateChecksum(op_type: WalOperation, key_len: u32, val_len: u32, offset: u64, key: []const u8) u32 {
        var crc = std.hash.Crc32.init();
        crc.update(std.mem.asBytes(&op_type));
        crc.update(std.mem.asBytes(&key_len));
        crc.update(std.mem.asBytes(&val_len));
        crc.update(std.mem.asBytes(&offset));
        crc.update(key);
        return crc.final();
    }

    fn verifyWalEntryIntegrity(header: *WalEntryHeader, key: []const u8) bool {
        const computed = calculateChecksum(header.op_type, @intCast(header.key_len), @intCast(header.val_len), header.offset, key);
        return computed == header.checksum;
    }
};

// ---------------------------------------------------------------

test "write_ahead_log:recover" {
    const allocator = std.testing.allocator;
    const path = "test.db";

    // Clean up any existing files
    try testCleanup();

    // Create a dummy Phage store
    var store = try Phage.init(allocator, path);
    errdefer store.deinit();
    defer store.deinit();

    // Simulate a WAL entry
    const key = "test_key";
    const value = "test_value";
    const offset = 0;
    const checksum = Wal.calculateChecksum(.put, @intCast(key.len), @intCast(value.len), offset, key);

    // Write the WAL entry to the file
    const entry_header = Wal.WalEntryHeader{
        .op_type = .put,
        .key_len = @intCast(key.len),
        .val_len = @intCast(value.len),
        .offset = offset,
        .checksum = checksum,
        .padding = 0,
    };

    _ = try std.posix.pwrite(store.wal_fd, std.mem.asBytes(&entry_header), 0);
    _ = try std.posix.pwrite(store.wal_fd, key, @sizeOf(Wal.WalEntryHeader));

    // Recover the WAL
    try Wal.recover(&store);

    // check the index entry recovered from the wal
    const index_entry = store.index.get(key);
    try expectNotNull(index_entry);
    const index_entry_value = index_entry.?;
    try std.testing.expectEqual(index_entry_value.offset, offset);
    try std.testing.expectEqual(index_entry_value.len, @sizeOf(EntryHeader) + key.len + value.len);
    try std.testing.expectEqual(index_entry_value.key_len, key.len);
    try std.testing.expectEqual(index_entry_value.val_len, value.len);

    try testCleanup();
}

test "write_ahead_log:recover_with_provisional_entries" {
    const allocator = std.testing.allocator;
    const path = "test.db";

    // Clean up any existing files
    try testCleanup();

    // Create a dummy Phage store
    var store = try Phage.init(allocator, path);
    errdefer store.deinit();
    defer store.deinit();

    // Simulate a WAL entry
    const key = "test_key";
    const value = "test_value";
    const offset = 0;
    const checksum = Wal.calculateChecksum(.put, @intCast(key.len), @intCast(value.len), offset, key);

    // Write the WAL entry to the file
    const entry_header = Wal.WalEntryHeader{
        .op_type = .put,
        .key_len = @intCast(key.len),
        .val_len = @intCast(value.len),
        .offset = offset,
        .checksum = checksum,
        .padding = 0,
    };

    _ = try std.posix.pwrite(store.wal_fd, std.mem.asBytes(&entry_header), 0);
    _ = try std.posix.pwrite(store.wal_fd, key, @sizeOf(Wal.WalEntryHeader));

    // Recover the WAL
    try Wal.recover(&store);

    // check the index entry recovered from the wal
    const index_entry = store.index.get(key);
    try expectNotNull(index_entry);
    const index_entry_value = index_entry.?;
    try std.testing.expectEqual(index_entry_value.offset, offset);
    try std.testing.expectEqual(index_entry_value.len, @sizeOf(EntryHeader) + key.len + value.len);
    try std.testing.expectEqual(index_entry_value.key_len, key.len);
    try std.testing.expectEqual(index_entry_value.val_len, value.len);

    try testCleanup();
}

fn testCleanup() !void {
    std.posix.unlink("test.db") catch {};
    std.posix.unlink("test.db.wal") catch {};
}

test "write_ahead_log:recover_committed_put_entry_reads_value" {
    const allocator = std.testing.allocator;
    const path = "test_wal_recover_committed.db";
    const wal_path = "test_wal_recover_committed.db.wal";

    cleanupFiles(path, wal_path);
    defer cleanupFiles(path, wal_path);

    var store = try Phage.init(allocator, path);
    defer store.deinit();

    const key = "recover-put";
    const value = "committed-value";
    const data_offset: usize = 0;
    _ = try writeDataEntry(store.fd, key, value, data_offset);
    const wal_len = try writeWalEntry(store.wal_fd, .put, key, value.len, data_offset, 0, null);
    store.wal_file_size.store(wal_len, .release);

    try Wal.recover(&store);

    const recovered = try store.get(key);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(value, recovered);
    try expectWalCleared(&store);
}

test "write_ahead_log:recover_skips_provisional_put_and_applies_final_put_at_zero_offset" {
    const allocator = std.testing.allocator;
    const path = "test_wal_recover_provisional.db";
    const wal_path = "test_wal_recover_provisional.db.wal";

    cleanupFiles(path, wal_path);
    defer cleanupFiles(path, wal_path);

    var store = try Phage.init(allocator, path);
    defer store.deinit();

    const key = "crash-key";
    const value = "durable-at-zero";
    const data_offset: usize = 0;
    _ = try writeDataEntry(store.fd, key, value, data_offset);

    var wal_offset: usize = 0;
    wal_offset += try writeWalEntry(store.wal_fd, .put, key, 0, 0, wal_offset, null);
    wal_offset += try writeWalEntry(store.wal_fd, .put, key, value.len, data_offset, wal_offset, null);
    store.wal_file_size.store(wal_offset, .release);

    try Wal.recover(&store);

    const recovered = try store.get(key);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(value, recovered);
    try expectWalCleared(&store);
}

test "write_ahead_log:recover_replays_delete_after_restore_index" {
    const allocator = std.testing.allocator;
    const path = "test_wal_recover_delete.db";
    const wal_path = "test_wal_recover_delete.db.wal";

    cleanupFiles(path, wal_path);
    defer cleanupFiles(path, wal_path);

    {
        var store = try Phage.init(allocator, path);
        defer store.deinit();

        try store.put("deleted-key", "old-value");
        try std.testing.expect(try store.delete("deleted-key"));
    }

    var recovered_store = try Phage.init(allocator, path);
    defer recovered_store.deinit();

    try std.testing.expectError(error.KeyNotFound, recovered_store.get("deleted-key"));
    try expectWalCleared(&recovered_store);
}

test "write_ahead_log:recover_preserves_valid_prefix_before_corrupt_tail" {
    const allocator = std.testing.allocator;
    const path = "test_wal_recover_corrupt_tail.db";
    const wal_path = "test_wal_recover_corrupt_tail.db.wal";

    cleanupFiles(path, wal_path);
    defer cleanupFiles(path, wal_path);

    var store = try Phage.init(allocator, path);
    defer store.deinit();

    const good_key = "safe-key";
    const good_value = "safe-value";
    const good_offset: usize = 0;
    _ = try writeDataEntry(store.fd, good_key, good_value, good_offset);

    var wal_offset: usize = 0;
    wal_offset += try writeWalEntry(store.wal_fd, .put, good_key, good_value.len, good_offset, wal_offset, null);
    wal_offset += try writeWalEntry(store.wal_fd, .put, "corrupt-key", 99, 4096, wal_offset, 0);
    store.wal_file_size.store(wal_offset, .release);

    try Wal.recover(&store);

    const recovered = try store.get(good_key);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(good_value, recovered);
    try std.testing.expectError(error.KeyNotFound, store.get("corrupt-key"));
    try expectWalCleared(&store);
}

test "write_ahead_log:recover_preserves_valid_prefix_before_truncated_tail" {
    const allocator = std.testing.allocator;
    const path = "test_wal_recover_truncated_tail.db";
    const wal_path = "test_wal_recover_truncated_tail.db.wal";

    cleanupFiles(path, wal_path);
    defer cleanupFiles(path, wal_path);

    var store = try Phage.init(allocator, path);
    defer store.deinit();

    const good_key = "prefix-key";
    const good_value = "prefix-value";
    const good_offset: usize = 0;
    _ = try writeDataEntry(store.fd, good_key, good_value, good_offset);

    var wal_offset: usize = 0;
    wal_offset += try writeWalEntry(store.wal_fd, .put, good_key, good_value.len, good_offset, wal_offset, null);

    const truncated_header = Wal.WalEntryHeader{
        .op_type = .put,
        .key_len = 16,
        .val_len = 5,
        .offset = 128,
        .checksum = 12345,
        .padding = 0,
    };
    const partial_header = std.mem.asBytes(&truncated_header)[0 .. @sizeOf(Wal.WalEntryHeader) - 3];
    try expectFullWrite(partial_header.len, try std.posix.pwrite(store.wal_fd, partial_header, wal_offset));
    wal_offset += partial_header.len;
    store.wal_file_size.store(wal_offset, .release);

    try Wal.recover(&store);

    const recovered = try store.get(good_key);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(good_value, recovered);
    try expectWalCleared(&store);
}

fn writeDataEntry(fd: std.posix.fd_t, key: []const u8, value: []const u8, offset: usize) !usize {
    const header = EntryHeader{
        .key_len = @intCast(key.len),
        .val_len = @intCast(value.len),
    };
    var cursor = offset;
    try expectFullWrite(@sizeOf(EntryHeader), try std.posix.pwrite(fd, std.mem.asBytes(&header), cursor));
    cursor += @sizeOf(EntryHeader);
    try expectFullWrite(key.len, try std.posix.pwrite(fd, key, cursor));
    cursor += key.len;
    try expectFullWrite(value.len, try std.posix.pwrite(fd, value, cursor));
    return @sizeOf(EntryHeader) + key.len + value.len;
}

fn writeWalEntry(
    fd: std.posix.fd_t,
    op_type: Wal.WalOperation,
    key: []const u8,
    val_len: usize,
    data_offset: usize,
    wal_offset: usize,
    checksum_override: ?u32,
) !usize {
    const header = Wal.WalEntryHeader{
        .op_type = op_type,
        .key_len = key.len,
        .val_len = val_len,
        .offset = data_offset,
        .checksum = checksum_override orelse Wal.calculateChecksum(op_type, @intCast(key.len), @intCast(val_len), data_offset, key),
        .padding = 0,
    };
    var cursor = wal_offset;
    try expectFullWrite(@sizeOf(Wal.WalEntryHeader), try std.posix.pwrite(fd, std.mem.asBytes(&header), cursor));
    cursor += @sizeOf(Wal.WalEntryHeader);
    try expectFullWrite(key.len, try std.posix.pwrite(fd, key, cursor));
    return @sizeOf(Wal.WalEntryHeader) + key.len;
}

fn expectFullWrite(expected: usize, actual: usize) !void {
    try std.testing.expectEqual(expected, actual);
}

fn expectWalCleared(store: *Phage) !void {
    const wal_stat = try std.posix.fstat(store.wal_fd);
    try std.testing.expectEqual(@as(i64, 0), wal_stat.size);
    try std.testing.expectEqual(@as(u64, 0), store.wal_file_size.load(.acquire));
}

fn cleanupFiles(path: []const u8, wal_path: []const u8) void {
    std.posix.unlink(path) catch {};
    std.posix.unlink(wal_path) catch {};
}

fn expectNotNull(value: anytype) !void {
    if (value == null) {
        return error.TestValueWasNull;
    }
}
