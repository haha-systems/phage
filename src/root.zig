const std = @import("std");
const linux = @import("std").os.linux;
const posix = @import("std").posix;
const log = @import("std").log;

const Allocator = std.mem.Allocator;
const BufferPool = @import("buffer_pool.zig").BufferPool;
const IndexManager = @import("index.zig").IndexManager;
const EntryHeader = @import("index.zig").EntryHeader;
const Wal = @import("wal.zig").Wal;
const IO = @import("io.zig").IO;

pub const Phage = struct {
    allocator: Allocator,
    ring: linux.IoUring,
    fd: posix.fd_t,
    wal_fd: posix.fd_t,
    file_size: std.atomic.Value(u64),
    wal_file_size: std.atomic.Value(u64),
    index: IndexManager,
    buffer_pool: BufferPool,
    pending_ops: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const RING_ENTRIES: u32 = 128;

    pub fn init(
        allocator: Allocator,
        file_path: []const u8,
    ) !Phage {
        var options = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_COOP_TASKRUN |
                linux.IORING_SETUP_SINGLE_ISSUER,
        });

        const ring = linux.IoUring.init_params(RING_ENTRIES, &options) catch |err| {
            return err;
        };

        const fd = try std.posix.open(
            file_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        const wal_path = std.fmt.allocPrint(allocator, "{s}.wal", .{file_path}) catch |err| {
            return err;
        };
        defer allocator.free(wal_path);

        const wal_fd = try std.posix.open(
            wal_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        // stat the data files to get their current size
        const file_stat = try std.posix.fstat(fd);
        const wal_file_stat = try std.posix.fstat(wal_fd);

        const file_size = std.atomic.Value(u64).init(@intCast(file_stat.size));
        const wal_file_size = std.atomic.Value(u64).init(@intCast(wal_file_stat.size));
        const index = try IndexManager.init(allocator);
        const buffer_pool = try BufferPool.init(allocator);

        return Phage{
            .allocator = allocator,
            .ring = ring,
            .fd = fd,
            .wal_fd = wal_fd,
            .file_size = file_size,
            .wal_file_size = wal_file_size,
            .index = index,
            .buffer_pool = buffer_pool,
        };
    }

    pub fn deinit(self: *Phage) void {
        self.ring.deinit();
        posix.close(self.fd);
        posix.close(self.wal_fd);
        self.index.deinit(self.allocator);
        self.buffer_pool.deinit(self.allocator);
    }

    /// Writes a key-value pair to the database.
    ///
    /// This function performs the following steps:
    /// 1. Writes a provisional entry to the Write-Ahead Log (WAL).
    /// 2. Writes the key-value pair to the main database file.
    /// 3. Updates the WAL entry with the offset of the key-value pair in the main file.
    /// 4. Updates the index with the key and its offset in the main file.
    ///
    /// The key and value are duplicated, so the caller must ensure they are not
    /// freed until the database is closed or the entry is deleted.
    ///
    pub fn put(self: *Phage, key: []const u8, value: []const u8) !void {
        // Step 1: Write provisional entry to WAL, we'll get the offset later
        const provisional_wal_entry = try self.formatWalEntry(.put, key, value, 0);
        defer self.allocator.free(provisional_wal_entry);

        const wal_offset = self.wal_file_size.fetchAdd(provisional_wal_entry.len, .monotonic);

        var ops_submitted = try self.writeToWal(provisional_wal_entry, wal_offset);
        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 2: Write to main file to secure the offset
        const data_entry = try self.formatDataEntry(key, value);
        defer self.allocator.free(data_entry);

        const data_offset = self.file_size.fetchAdd(data_entry.len, .monotonic);
        ops_submitted = try IO.writeToFile(&self.pending_ops, self.fd, &self.ring, &data_entry, data_offset);

        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 3: Update WAL entry with the offset
        const final_wal_entry = try self.formatWalEntry(.put, key, value, data_offset);
        defer self.allocator.free(final_wal_entry);
        ops_submitted = try self.writeToWal(final_wal_entry, wal_offset);
        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 4: Finally, we update the index
        try self.index.put(self.allocator, key, .{
            .offset = data_offset,
            .len = data_entry.len,
            .key_len = key.len,
            .val_len = value.len,
        });
    }

    /// Reads a value from the database using the provided key.
    ///
    /// This function performs the following steps:
    /// 1. Retrieves the entry from the index using the key.
    /// 2. Allocates a buffer to read the entry from the main database file.
    /// 3. Reads the entry from the main database file.
    /// 4. Validates the key and extracts the value.
    /// 5. Returns the value to the caller.
    ///
    /// The caller is responsible for freeing the returned value.
    /// If the key is not found, an error is returned.
    pub fn get(self: *Phage, key: []const u8) ![]u8 {
        const entry = self.index.get(key) orelse return error.KeyNotFound;
        const buf = try self.allocator.alloc(u8, entry.len);
        defer self.allocator.free(buf);

        const ops_submitted = try IO.readFromFile(&self.pending_ops, self.fd, &self.ring, &buf, entry.offset);
        if (ops_submitted < 1) {
            return error.ReadError;
        }

        try waitForIO(self);

        const key_start = @sizeOf(EntryHeader);
        const stored_key = buf[key_start..][0..entry.key_len];
        if (!std.mem.eql(u8, stored_key, key)) return error.KeyMismatch;

        const val_start = key_start + entry.key_len;
        const value = buf[val_start..][0..entry.val_len];

        // note: caller now owns the value
        return self.allocator.dupe(u8, value) catch |err| {
            return err;
        };
    }

    /// Deletes a key-value pair from the database using the provided key.
    ///
    /// This function performs the following steps:
    /// 1. Writes a delete entry to the Write-Ahead Log (WAL).
    /// 2. Updates the index to remove the key.
    /// 3. Returns true if the key was successfully deleted, false otherwise.
    ///
    /// The key is duplicated, so the caller must ensure it is not freed until the
    /// database is closed or the entry is deleted.
    ///
    /// If the key is not found, an error is returned.
    pub fn delete(self: *Phage, key: []const u8) !bool {
        const wal_entry = try self.formatWalEntry(.delete, key, null, 0);
        defer self.allocator.free(wal_entry);

        const wal_offset = self.wal_file_size.fetchAdd(wal_entry.len, .monotonic);

        const ops_submitted = try self.writeToWal(wal_entry, wal_offset);
        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        return try self.index.delete(self.allocator, key);
    }

    /// Waits for all pending I/O operations to complete.
    fn waitForIO(self: *Phage) !void {
        while (self.pending_ops.load(.acquire) > 0) {
            // var cqe: linux.io_uring_cqe = undefined;
            const cqe = try self.ring.copy_cqe();
            if (cqe.res < 0) return error.IOUringError;
            const completed = self.pending_ops.fetchSub(1, .monotonic);
            if (completed == 0) {
                // No more pending operations
                break;
            }
        }
    }

    /// Formats a WAL entry with the given operation, key, value, and offset.
    /// Returns a buffer containing the serialized entry.
    /// The caller is responsible for freeing the buffer.
    /// The offset is used to store the location of the entry in the main database file.
    /// The value is optional and should be null for delete operations.
    ///
    /// See `Wal.WalEntryHeader` for the format of the entry.
    fn formatWalEntry(self: *Phage, op: Wal.WalOperation, key: []const u8, value: ?[]const u8, offset: usize) ![]u8 {
        // Calculate sizes
        const header_size = @sizeOf(Wal.WalEntryHeader); // 32 bytes
        const total_size = header_size + key.len;

        // Allocate buffer
        const buf = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(buf);

        const val_len = if (op == Wal.WalOperation.put) value.?.len else 0;

        // Create header
        const header = Wal.WalEntryHeader{
            .op_type = op,
            .key_len = key.len,
            .val_len = val_len,
            .offset = offset,
            .checksum = Wal.calculateChecksum(op, @intCast(key.len), @intCast(val_len), offset, key),
            .padding = 0,
        };

        // Serialize header
        @memcpy(buf[0..header_size], std.mem.asBytes(&header));

        // Append key
        @memcpy(buf[header_size..], key);

        return buf;
    }

    /// Formats a data entry with the given key and value.
    /// Returns a buffer containing the serialized entry.
    /// The caller is responsible for freeing the buffer.
    ///
    /// See `EntryHeader` for the format of the entry.
    fn formatDataEntry(self: *Phage, key: []const u8, value: []const u8) ![]u8 {
        // Validate sizes to prevent overflow
        if (key.len > std.math.maxInt(u32) or value.len > std.math.maxInt(u32)) {
            return error.ValueTooLarge;
        }

        // Calculate sizes
        const header_size = @sizeOf(EntryHeader); // 8 bytes
        const total_size = header_size + key.len + value.len;

        // Allocate buffer
        const buf = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(buf);

        // Create header
        const header = EntryHeader{
            .key_len = @intCast(key.len),
            .val_len = @intCast(value.len),
        };

        // Serialize header
        @memcpy(buf[0..header_size], std.mem.asBytes(&header));

        // Append key and value
        @memcpy(buf[header_size .. header_size + key.len], key);
        @memcpy(buf[header_size + key.len ..], value);

        return buf;
    }

    fn readFromWal(store: *Phage, buf: []u8, offset: usize) !usize {
        var sqe = try store.ring.get_sqe();
        sqe.prep_read(
            store.wal_fd,
            buf,
            offset,
        );
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try store.ring.submit();
        const pending = try store.pending_ops.fetchAdd(1, .monotonic);
        return submitted + pending;
    }

    fn writeToWal(store: *Phage, buf: []u8, offset: usize) !usize {
        var sqe = try store.ring.get_sqe();
        sqe.prep_write(
            store.wal_fd,
            buf,
            offset,
        );
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try store.ring.submit();
        const pending = store.pending_ops.fetchAdd(submitted, .monotonic);
        return submitted + pending;
    }
};

test "init" {
    const allocator = std.testing.allocator;
    const file_path = "test.db";

    var store = try Phage.init(allocator, file_path);
    defer store.deinit();
}

test "formatWalEntry" {
    const allocator = std.testing.allocator;

    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();

    const buf = try store.formatWalEntry(.put, "test_key", "test_value", 0);
    defer allocator.free(buf);

    try std.testing.expectEqual(@sizeOf(Wal.WalEntryHeader) + 8, buf.len);
    const header: *const Wal.WalEntryHeader = @ptrCast(@alignCast(buf.ptr));
    try std.testing.expectEqual(Wal.WalOperation.put, header.op_type);
    try std.testing.expectEqual(8, header.key_len);
    try std.testing.expectEqual(10, header.val_len);

    // cleanup test db
    try testCleanup();
}

test "formatDataEntry" {
    const allocator = std.testing.allocator;

    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();

    const buf = try store.formatDataEntry("test_key", "test_value");
    defer allocator.free(buf);

    try std.testing.expectEqual(@sizeOf(EntryHeader) + 8 + 10, buf.len);
    const header: *const EntryHeader = @ptrCast(@alignCast(buf.ptr));
    try std.testing.expectEqual(8, header.key_len);
    try std.testing.expectEqual(10, header.val_len);

    // cleanup test db
    try testCleanup();
}

test "put and get key/value" {
    const allocator = std.testing.allocator;
    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();
    errdefer testCleanup() catch unreachable;

    try store.put("key1", "value1");
    try store.put("key2", "value2");

    const val1 = try store.get("key1");
    defer allocator.free(val1);
    try std.testing.expectEqualStrings("value1", val1);

    const val2 = try store.get("key2");
    defer allocator.free(val2);
    try std.testing.expectEqualStrings("value2", val2);

    // cleanup test db
    try testCleanup();
}

test "delete key" {
    const allocator = std.testing.allocator;
    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();
    errdefer testCleanup() catch unreachable;

    try store.put("key1", "value1");
    const deleted = try store.delete("key1");
    try std.testing.expect(deleted);

    // We expect a KeyNotFound error here
    const result = store.get("key1");
    try std.testing.expectError(error.KeyNotFound, result);

    // cleanup test db
    try testCleanup();
}

fn testCleanup() !void {
    try std.posix.unlink("test.db");
    try std.posix.unlink("test.db.wal");
}
