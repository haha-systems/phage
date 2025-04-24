const std = @import("std");
const Phage = @import("root.zig").Phage;
const IndexEntry = @import("index.zig").IndexEntry;
const EntryHeader = @import("index.zig").EntryHeader;

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
        store.wal_file_size.store(@intCast(wal_file_stat.size), .release);

        // check if the wal file is empty with the new size
        if (store.wal_file_size.load(.acquire) == 0) {
            std.log.info("WAL file is empty, nothing to recover", .{});
            return;
        }

        var offset: usize = 0;
        while (offset < store.wal_file_size.load(.acquire)) {
            var header_buf: [@sizeOf(WalEntryHeader)]u8 = undefined;
            const header_read = try std.posix.pread(store.wal_fd, &header_buf, offset);
            if (header_read < @sizeOf(WalEntryHeader)) break;

            const header: WalEntryHeader = @bitCast(header_buf);

            const key_buf = try store.allocator.alloc(u8, header.key_len);
            defer store.allocator.free(key_buf);
            const key_read = try std.posix.pread(store.wal_fd, key_buf, offset + @sizeOf(WalEntryHeader));
            if (key_read < header.key_len) break;

            if (calculateChecksum(header.op_type, @intCast(header.key_len), @intCast(header.val_len), header.offset, key_buf) != header.checksum) {
                return error.ChecksumMismatch;
            }

            switch (header.op_type) {
                .put => {
                    // We may have provisional entries in the WAL that haven't been written to the main file
                    // yet for whatever reason. If we find any, just skip them as we haven't guaranteed them yet.
                    if (header.offset == 0) continue;

                    try store.index.put(store.allocator, key_buf, .{
                        .offset = header.offset,
                        .len = @sizeOf(EntryHeader) + header.key_len + header.val_len,
                        .key_len = header.key_len,
                        .val_len = header.val_len,
                    });
                },
                .delete => try store.index.delete(key_buf),
            }

            offset += @sizeOf(WalEntryHeader) + header.key_len;
        }
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

test "recover" {
    const allocator = std.testing.allocator;
    const path = "test.db";

    // Clean up any existing files
    try testCleanup();

    // Create a dummy Phage store
    var store = try Phage.init(allocator, path);
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

test "recover with provisional entries" {
    const allocator = std.testing.allocator;
    const path = "test.db";

    // Clean up any existing files
    try testCleanup();

    // Create a dummy Phage store
    var store = try Phage.init(allocator, path);
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

fn expectNotNull(value: anytype) !void {
    if (value == null) {
        return error.TestValueWasNull;
    }
}
