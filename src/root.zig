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

    pub fn put(self: *Phage, key: []const u8, value: []const u8) !void {
        // Step 1: Log to WAL
        const wal_entry = try self.formatWalEntry(key, value);
        // defer self.buffer_pool.release(wal_entry) catch unreachable;
        defer self.allocator.free(wal_entry);

        const wal_offset = self.wal_file_size.fetchAdd(wal_entry.len, .monotonic);

        var ops_submitted = try self.writeToWal(wal_entry, wal_offset);
        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 2: Write to main file
        const data_entry = try self.formatDataEntry(key, value);
        defer self.allocator.free(data_entry);

        const data_offset = self.file_size.fetchAdd(data_entry.len, .monotonic);
        ops_submitted = try IO.writeToFile(&self.pending_ops, self.fd, &self.ring, &data_entry, data_offset);

        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 3: Update index
        try self.index.put(self.allocator, key, .{
            .offset = data_offset,
            .len = data_entry.len,
            .key_len = key.len,
            .val_len = value.len,
        });
    }

    pub fn get(self: *Phage, key: []const u8) ![]u8 {
        const entry = self.index.get(key) orelse return error.KeyNotFound;
        const buf = try self.allocator.alloc(u8, entry.len);
        defer self.allocator.free(buf);

        const ops_submitted = try IO.readFromFile(&self.pending_ops, self.fd, &self.ring, &buf, entry.offset);
        if (ops_submitted < 1) {
            return error.ReadError;
        }

        // Wait for IO to complete
        try waitForIO(self);

        // validate and extract value
        const key_start = @sizeOf(EntryHeader);
        const stored_key = buf[key_start..][0..entry.key_len];
        if (!std.mem.eql(u8, stored_key, key)) return error.KeyMismatch;

        const val_start = key_start + entry.key_len;
        const value = buf[val_start..][0..entry.val_len];

        // caller now owns the value
        return self.allocator.dupe(u8, value) catch |err| {
            return err;
        };
    }

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

    fn formatWalEntry(self: *Phage, key: []const u8, value: []const u8) ![]u8 {
        // Calculate sizes
        const header_size = @sizeOf(Wal.WalEntryHeader); // 32 bytes
        const total_size = header_size + key.len;

        // Allocate buffer
        const buf = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(buf);

        // Create header
        const offset = 0; // Will be set by caller (e.g., file_size)
        const header = Wal.WalEntryHeader{
            .op_type = .put,
            .key_len = key.len,
            .val_len = value.len,
            .offset = offset, // Placeholder; updated by put
            .checksum = Wal.calculateChecksum(.put, @intCast(key.len), @intCast(value.len), offset, key),
            .padding = 0,
        };

        // Serialize header
        @memcpy(buf[0..header_size], std.mem.asBytes(&header));

        // Append key
        @memcpy(buf[header_size..], key);

        return buf;
    }

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
    const buf = try store.formatWalEntry("test_key", "test_value");
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

fn testCleanup() !void {
    try std.posix.unlink("test.db");
    try std.posix.unlink("test.db.wal");
}
