const std = @import("std");
const builtin = @import("builtin");

pub const BackendKind = enum {
    linux_iouring,
    posix,
};

pub const default_kind: BackendKind = if (builtin.os.tag == .linux) .linux_iouring else .posix;

pub const Backend = switch (default_kind) {
    .linux_iouring => LinuxIoUringBackend,
    .posix => PosixBackend,
};

pub const WriteOperation = struct {
    fd: std.posix.fd_t,
    buf: []const u8,
    offset: u64,
};

const RING_ENTRIES: u32 = 128;
const backend_test_path = ".zig-cache/phage-tests/backend_io.db";

const PosixBackend = struct {
    pub fn init() !PosixBackend {
        return .{};
    }

    pub fn deinit(_: *PosixBackend) void {}

    pub fn read(_: *PosixBackend, fd: std.posix.fd_t, buf: []u8, offset: u64) !usize {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const bytes_read = try std.posix.pread(fd, buf[total_read..], offset + total_read);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        if (total_read != buf.len) return error.ReadError;
        return 1;
    }

    pub fn write(_: *PosixBackend, fd: std.posix.fd_t, buf: []const u8, offset: u64) !usize {
        var total_written: usize = 0;
        while (total_written < buf.len) {
            const bytes_written = try std.posix.pwrite(fd, buf[total_written..], offset + total_written);
            if (bytes_written == 0) return error.WriteError;
            total_written += bytes_written;
        }

        return 1;
    }

    pub fn writeMany(self: *PosixBackend, operations: []const WriteOperation) !usize {
        for (operations) |operation| {
            _ = try self.write(operation.fd, operation.buf, operation.offset);
        }
        return operations.len;
    }

    pub fn wait(_: *PosixBackend) !void {}
};

const LinuxIoUringBackend = struct {
    const linux = std.os.linux;

    ring: linux.IoUring,
    pending_ops: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init() !LinuxIoUringBackend {
        var options = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_COOP_TASKRUN,
            .sq_thread_idle = 1,
            .sq_thread_cpu = 0,
        });

        return .{
            .ring = try linux.IoUring.init_params(RING_ENTRIES, &options),
        };
    }

    pub fn deinit(self: *LinuxIoUringBackend) void {
        self.ring.deinit();
    }

    pub fn read(self: *LinuxIoUringBackend, fd: std.posix.fd_t, buf: []u8, offset: u64) !usize {
        var sqe = try self.ring.get_sqe();
        sqe.prep_read(fd, buf, offset);
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try self.ring.submit();
        const pending = self.pending_ops.fetchAdd(1, .monotonic);
        return submitted + pending;
    }

    pub fn write(self: *LinuxIoUringBackend, fd: std.posix.fd_t, buf: []const u8, offset: u64) !usize {
        const operation = WriteOperation{ .fd = fd, .buf = buf, .offset = offset };
        return try self.writeMany(&.{operation});
    }

    pub fn writeMany(self: *LinuxIoUringBackend, operations: []const WriteOperation) !usize {
        if (operations.len == 0) return 0;
        if (operations.len > RING_ENTRIES) return error.TooManyOperations;

        for (operations) |operation| {
            var sqe = try self.ring.get_sqe();
            sqe.prep_write(operation.fd, operation.buf, operation.offset);
            sqe.flags |= linux.IOSQE_ASYNC;
            sqe.user_data = @intFromPtr(operation.buf.ptr);
        }

        const submitted = try self.ring.submit();
        if (submitted != operations.len) return error.WriteError;

        _ = self.pending_ops.fetchAdd(@intCast(submitted), .monotonic);
        return submitted;
    }

    pub fn wait(self: *LinuxIoUringBackend) !void {
        while (self.pending_ops.load(.acquire) > 0) {
            const cqe = try self.ring.copy_cqe();
            if (cqe.res < 0) return error.IOUringError;
            const completed = self.pending_ops.fetchSub(1, .monotonic);
            if (completed == 0) break;
        }
    }
};

test "default backend preserves io_uring on Linux and uses POSIX elsewhere" {
    const expected: BackendKind = if (builtin.os.tag == .linux) .linux_iouring else .posix;
    try std.testing.expectEqual(expected, default_kind);
}

test "selected backend supports positioned read/write and wait" {
    const path = backend_test_path;
    try std.fs.cwd().makePath(".zig-cache/phage-tests");
    std.posix.unlink(path) catch {};
    defer std.posix.unlink(path) catch {};

    const fd = try std.posix.open(
        path,
        .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        },
        std.posix.S.IRUSR | std.posix.S.IWUSR,
    );
    defer std.posix.close(fd);

    var backend = try Backend.init();
    defer backend.deinit();

    const written = try backend.write(fd, "hello", 2);
    try std.testing.expect(written >= 1);
    try backend.wait();

    var buf: [5]u8 = undefined;
    const read = try backend.read(fd, &buf, 2);
    try std.testing.expect(read >= 1);
    try backend.wait();

    try std.testing.expectEqualStrings("hello", &buf);
}

test "selected backend supports positioned multi-write submission" {
    const path = ".zig-cache/phage-tests/backend_multi_write.db";
    try std.fs.cwd().makePath(".zig-cache/phage-tests");
    std.posix.unlink(path) catch {};
    defer std.posix.unlink(path) catch {};

    const fd = try std.posix.open(
        path,
        .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        },
        std.posix.S.IRUSR | std.posix.S.IWUSR,
    );
    defer std.posix.close(fd);

    var backend = try Backend.init();
    defer backend.deinit();

    const writes = [_]WriteOperation{
        .{ .fd = fd, .buf = "data", .offset = 4 },
        .{ .fd = fd, .buf = "wal", .offset = 16 },
    };
    const submitted = try backend.writeMany(&writes);
    try std.testing.expectEqual(@as(usize, writes.len), submitted);
    try backend.wait();

    var data_buf: [4]u8 = undefined;
    var wal_buf: [3]u8 = undefined;
    _ = try backend.read(fd, &data_buf, 4);
    try backend.wait();
    _ = try backend.read(fd, &wal_buf, 16);
    try backend.wait();

    try std.testing.expectEqualStrings("data", &data_buf);
    try std.testing.expectEqualStrings("wal", &wal_buf);
}
