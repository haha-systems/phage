const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

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

fn rollbackQueuedSqes(comptime Ring: type, ring: *Ring, queued: u32) void {
    if (queued == 0) return;

    if (@hasDecl(Ring, "rollbackQueued")) {
        ring.rollbackQueued(queued);
    } else if (Ring == linux.IoUring) {
        ring.sq.sqe_tail -%= queued;
    } else {
        @compileError("ring type must provide rollbackQueued or be linux.IoUring");
    }
}

fn discardUnsubmittedSqes(comptime Ring: type, ring: *Ring, unsubmitted: u32) void {
    if (unsubmitted == 0) return;

    if (@hasDecl(Ring, "rollbackQueued")) {
        ring.rollbackQueued(unsubmitted);
    } else if (Ring == linux.IoUring) {
        const head = @atomicLoad(u32, ring.sq.head, .acquire);
        ring.sq.sqe_head = head;
        ring.sq.sqe_tail = head;
        @atomicStore(u32, ring.sq.tail, head, .release);
    } else {
        @compileError("ring type must provide rollbackQueued or be linux.IoUring");
    }
}

fn drainSubmittedCompletions(comptime Ring: type, ring: *Ring, pending_ops: *std.atomic.Value(u32), submitted: u32) !void {
    if (submitted == 0) return;

    _ = pending_ops.fetchAdd(submitted, .monotonic);
    var remaining = submitted;
    var completion_error: ?anyerror = null;
    while (remaining > 0) : (remaining -= 1) {
        const cqe = try ring.copy_cqe();
        _ = pending_ops.fetchSub(1, .monotonic);
        if (cqe.res < 0 and completion_error == null) completion_error = error.IOUringError;
    }

    if (completion_error) |err| return err;
}

fn waitWithRing(comptime Ring: type, ring: *Ring, pending_ops: *std.atomic.Value(u32)) !void {
    var completion_error: ?anyerror = null;
    while (pending_ops.load(.acquire) > 0) {
        const cqe = try ring.copy_cqe();
        const completed = pending_ops.fetchSub(1, .monotonic);
        if (completed == 0) break;
        if (cqe.res < 0 and completion_error == null) completion_error = error.IOUringError;
    }

    if (completion_error) |err| return err;
}

fn writeManyWithRing(comptime Ring: type, ring: *Ring, pending_ops: *std.atomic.Value(u32), operations: []const WriteOperation) !usize {
    if (operations.len == 0) return 0;
    if (operations.len > RING_ENTRIES) return error.TooManyOperations;

    var staged: u32 = 0;
    errdefer rollbackQueuedSqes(Ring, ring, staged);

    for (operations) |operation| {
        var sqe = try ring.get_sqe();
        staged += 1;
        sqe.prep_write(operation.fd, operation.buf, operation.offset);
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(operation.buf.ptr);
    }

    const queued = staged;
    staged = 0;

    var submitted_total: u32 = 0;
    while (submitted_total < queued) {
        const submitted = ring.submit() catch |err| {
            discardUnsubmittedSqes(Ring, ring, queued - submitted_total);
            try drainSubmittedCompletions(Ring, ring, pending_ops, submitted_total);
            return err;
        };
        if (submitted == 0 or submitted_total + submitted > queued) {
            discardUnsubmittedSqes(Ring, ring, queued - submitted_total);
            try drainSubmittedCompletions(Ring, ring, pending_ops, submitted_total);
            return error.WriteError;
        }
        submitted_total += submitted;
    }

    _ = pending_ops.fetchAdd(submitted_total, .monotonic);
    return submitted_total;
}

fn readWithRing(comptime Ring: type, ring: *Ring, pending_ops: *std.atomic.Value(u32), fd: std.posix.fd_t, buf: []u8, offset: u64) !usize {
    var staged: u32 = 0;
    errdefer rollbackQueuedSqes(Ring, ring, staged);

    var sqe = try ring.get_sqe();
    staged = 1;
    sqe.prep_read(fd, buf, offset);
    sqe.flags |= linux.IOSQE_ASYNC;
    sqe.user_data = @intFromPtr(buf.ptr);

    const queued = staged;
    staged = 0;

    var submitted_total: u32 = 0;
    while (submitted_total < queued) {
        const submitted = ring.submit() catch |err| {
            discardUnsubmittedSqes(Ring, ring, queued - submitted_total);
            try drainSubmittedCompletions(Ring, ring, pending_ops, submitted_total);
            return err;
        };
        if (submitted == 0 or submitted_total + submitted > queued) {
            discardUnsubmittedSqes(Ring, ring, queued - submitted_total);
            try drainSubmittedCompletions(Ring, ring, pending_ops, submitted_total);
            return error.ReadError;
        }
        submitted_total += submitted;
    }

    _ = pending_ops.fetchAdd(submitted_total, .monotonic);
    return submitted_total;
}

const LinuxIoUringBackend = struct {
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
        return try readWithRing(linux.IoUring, &self.ring, &self.pending_ops, fd, buf, offset);
    }

    pub fn write(self: *LinuxIoUringBackend, fd: std.posix.fd_t, buf: []const u8, offset: u64) !usize {
        const operation = WriteOperation{ .fd = fd, .buf = buf, .offset = offset };
        return try self.writeMany(&.{operation});
    }

    pub fn writeMany(self: *LinuxIoUringBackend, operations: []const WriteOperation) !usize {
        return try writeManyWithRing(linux.IoUring, &self.ring, &self.pending_ops, operations);
    }

    pub fn wait(self: *LinuxIoUringBackend) !void {
        try waitWithRing(linux.IoUring, &self.ring, &self.pending_ops);
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

const FakeCqe = struct {
    res: i32,
};

const FakeSqe = struct {
    flags: u32 = 0,
    user_data: usize = 0,
    fd: std.posix.fd_t = -1,
    buf_len: usize = 0,
    offset: u64 = 0,

    fn prep_write(self: *FakeSqe, fd: std.posix.fd_t, buf: []const u8, offset: u64) void {
        self.fd = fd;
        self.buf_len = buf.len;
        self.offset = offset;
    }

    fn prep_read(self: *FakeSqe, fd: std.posix.fd_t, buf: []u8, offset: u64) void {
        self.fd = fd;
        self.buf_len = buf.len;
        self.offset = offset;
    }
};

const FakeSubmitResult = union(enum) {
    submitted: u32,
    err: anyerror,
};

const FakeRing = struct {
    sqes: [4]FakeSqe = [_]FakeSqe{.{}} ** 4,
    queued: u32 = 0,
    fail_get_sqe_after: ?u32 = null,
    submit_results: []const FakeSubmitResult = &.{},
    submit_index: usize = 0,
    submit_calls: usize = 0,
    completion_results: []const i32 = &.{},
    completion_index: usize = 0,
    completions_ready: u32 = 0,

    fn get_sqe(self: *FakeRing) !*FakeSqe {
        if (self.fail_get_sqe_after) |limit| {
            if (self.queued >= limit) return error.SubmissionQueueFull;
        }
        const index = self.queued;
        self.queued += 1;
        return &self.sqes[index];
    }

    fn rollbackQueued(self: *FakeRing, count: u32) void {
        self.queued -= count;
    }

    fn submit(self: *FakeRing) !u32 {
        self.submit_calls += 1;
        if (self.submit_index >= self.submit_results.len) return error.UnexpectedSubmit;
        const result = self.submit_results[self.submit_index];
        self.submit_index += 1;
        switch (result) {
            .submitted => |submitted| {
                self.queued -= submitted;
                self.completions_ready += submitted;
                return submitted;
            },
            .err => |err| return err,
        }
    }

    fn copy_cqe(self: *FakeRing) !FakeCqe {
        if (self.completions_ready == 0) return error.NoCompletion;
        self.completions_ready -= 1;
        const result = if (self.completion_index < self.completion_results.len) self.completion_results[self.completion_index] else 1;
        self.completion_index += 1;
        return .{ .res = result };
    }
};

test "linux writeMany rolls back staged SQEs when queueing fails" {
    var ring = FakeRing{ .fail_get_sqe_after = 1 };
    var pending_ops = std.atomic.Value(u32).init(0);
    const writes = [_]WriteOperation{
        .{ .fd = 1, .buf = "first", .offset = 0 },
        .{ .fd = 1, .buf = "second", .offset = 8 },
    };

    try std.testing.expectError(error.SubmissionQueueFull, writeManyWithRing(FakeRing, &ring, &pending_ops, &writes));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(usize, 0), ring.submit_calls);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
}

test "linux writeMany retries short submits before exposing buffers to callers" {
    const submit_results = [_]FakeSubmitResult{
        .{ .submitted = 1 },
        .{ .submitted = 1 },
    };
    var ring = FakeRing{ .submit_results = &submit_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    const writes = [_]WriteOperation{
        .{ .fd = 1, .buf = "first", .offset = 0 },
        .{ .fd = 1, .buf = "second", .offset = 8 },
    };

    const submitted = try writeManyWithRing(FakeRing, &ring, &pending_ops, &writes);

    try std.testing.expectEqual(@as(usize, writes.len), submitted);
    try std.testing.expectEqual(@as(usize, 2), ring.submit_calls);
    try std.testing.expectEqual(@as(u32, writes.len), pending_ops.load(.acquire));
}

test "linux writeMany drains already submitted writes before returning submit failure" {
    const submit_results = [_]FakeSubmitResult{
        .{ .submitted = 1 },
        .{ .err = error.WriteError },
    };
    var ring = FakeRing{ .submit_results = &submit_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    const writes = [_]WriteOperation{
        .{ .fd = 1, .buf = "first", .offset = 0 },
        .{ .fd = 1, .buf = "second", .offset = 8 },
    };

    try std.testing.expectError(error.WriteError, writeManyWithRing(FakeRing, &ring, &pending_ops, &writes));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), ring.completions_ready);
}

test "linux writeMany rolls back queued SQEs when submit fails before acceptance" {
    const submit_results = [_]FakeSubmitResult{.{ .err = error.WriteError }};
    var ring = FakeRing{ .submit_results = &submit_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    const writes = [_]WriteOperation{
        .{ .fd = 1, .buf = "first", .offset = 0 },
        .{ .fd = 1, .buf = "second", .offset = 8 },
    };

    try std.testing.expectError(error.WriteError, writeManyWithRing(FakeRing, &ring, &pending_ops, &writes));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), ring.completions_ready);
}

test "linux wait drains all pending completions even when one CQE fails" {
    const completion_results = [_]i32{ -5, 1 };
    var ring = FakeRing{ .completion_results = &completion_results, .completions_ready = 2 };
    var pending_ops = std.atomic.Value(u32).init(2);

    try std.testing.expectError(error.IOUringError, waitWithRing(FakeRing, &ring, &pending_ops));
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), ring.completions_ready);
    try std.testing.expectEqual(@as(usize, 2), ring.completion_index);
}

test "linux writeMany drains all submitted completions even when one CQE fails" {
    const submit_results = [_]FakeSubmitResult{
        .{ .submitted = 2 },
        .{ .err = error.WriteError },
    };
    const completion_results = [_]i32{ -5, 1 };
    var ring = FakeRing{ .submit_results = &submit_results, .completion_results = &completion_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    const writes = [_]WriteOperation{
        .{ .fd = 1, .buf = "first", .offset = 0 },
        .{ .fd = 1, .buf = "second", .offset = 8 },
        .{ .fd = 1, .buf = "third", .offset = 16 },
    };

    try std.testing.expectError(error.IOUringError, writeManyWithRing(FakeRing, &ring, &pending_ops, &writes));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), ring.completions_ready);
    try std.testing.expectEqual(@as(usize, 2), ring.completion_index);
}

test "linux writeMany rolls back queued SQEs when submit returns zero" {
    const submit_results = [_]FakeSubmitResult{.{ .submitted = 0 }};
    var ring = FakeRing{ .submit_results = &submit_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    const writes = [_]WriteOperation{
        .{ .fd = 1, .buf = "first", .offset = 0 },
        .{ .fd = 1, .buf = "second", .offset = 8 },
    };

    try std.testing.expectError(error.WriteError, writeManyWithRing(FakeRing, &ring, &pending_ops, &writes));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
}

test "linux read uses safe submission accounting on submit failure" {
    const submit_results = [_]FakeSubmitResult{.{ .err = error.WriteError }};
    var ring = FakeRing{ .submit_results = &submit_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    var buf: [4]u8 = undefined;

    try std.testing.expectError(error.WriteError, readWithRing(FakeRing, &ring, &pending_ops, 1, &buf, 0));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
}

test "linux read rejects zero submit without pending leak" {
    const submit_results = [_]FakeSubmitResult{.{ .submitted = 0 }};
    var ring = FakeRing{ .submit_results = &submit_results };
    var pending_ops = std.atomic.Value(u32).init(0);
    var buf: [4]u8 = undefined;

    try std.testing.expectError(error.ReadError, readWithRing(FakeRing, &ring, &pending_ops, 1, &buf, 0));
    try std.testing.expectEqual(@as(u32, 0), ring.queued);
    try std.testing.expectEqual(@as(u32, 0), pending_ops.load(.acquire));
}
