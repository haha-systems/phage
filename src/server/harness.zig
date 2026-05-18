const std = @import("std");

pub const Error = error{HarnessDeadlineExceeded};

pub const Context = struct {
    name: []const u8,
    db_path: []const u8,
    port: u16,
    clients: usize,
    requests_per_client: usize,
};

pub const Deadline = struct {
    started_ms: i64,
    deadline_ms: i64,

    pub fn init(duration_ms: i64) Deadline {
        const started_ms = std.time.milliTimestamp();
        return .{ .started_ms = started_ms, .deadline_ms = started_ms + duration_ms };
    }

    pub fn durationMs(self: Deadline) i64 {
        return self.deadline_ms - self.started_ms;
    }

    pub fn elapsedMsAt(self: Deadline, now_ms: i64) i64 {
        return now_ms - self.started_ms;
    }

    pub fn remainingMsAt(self: Deadline, now_ms: i64) i64 {
        return self.deadline_ms - now_ms;
    }

    pub fn expiredAt(self: Deadline, now_ms: i64) bool {
        return self.remainingMsAt(now_ms) <= 0;
    }

    pub fn ensure(self: Deadline, phase: []const u8, context: Context) Error!void {
        const now_ms = std.time.milliTimestamp();
        if (!self.expiredAt(now_ms)) return;
        reportTimeout(phase, context, self, now_ms);
        return error.HarnessDeadlineExceeded;
    }
};

pub fn writeTimeoutReport(writer: *std.io.AnyWriter, phase: []const u8, context: Context, deadline: Deadline, now_ms: i64) !void {
    try writer.print(
        "error: server harness timeout phase={s} harness={s} clients={d} requests_per_client={d} port={d} db_path={s} elapsed_ms={d} deadline_ms={d}\n",
        .{
            phase,
            context.name,
            context.clients,
            context.requests_per_client,
            context.port,
            context.db_path,
            deadline.elapsedMsAt(now_ms),
            deadline.durationMs(),
        },
    );
}

pub fn reportTimeout(phase: []const u8, context: Context, deadline: Deadline, now_ms: i64) void {
    var stderr = std.fs.File.stderr().deprecatedWriter().any();
    writeTimeoutReport(&stderr, phase, context, deadline, now_ms) catch {};
}

pub fn cleanupStoreFiles(db_path: []const u8) !void {
    try deleteIfExists(db_path);

    var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{db_path});
    try deleteIfExists(wal_path);

    var compact_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try std.fmt.bufPrint(&compact_path_buf, "{s}.compact.tmp", .{db_path});
    try deleteIfExists(compact_path);
}

pub fn storeArtifactsExist(allocator: std.mem.Allocator, db_path: []const u8) !bool {
    if (try fileExists(db_path)) return true;
    const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{db_path});
    defer allocator.free(wal_path);
    if (try fileExists(wal_path)) return true;
    const compact_path = try std.fmt.allocPrint(allocator, "{s}.compact.tmp", .{db_path});
    defer allocator.free(compact_path);
    return try fileExists(compact_path);
}

pub fn storeArtifactsClean(allocator: std.mem.Allocator, db_path: []const u8) !bool {
    return !(try storeArtifactsExist(allocator, db_path));
}

pub fn terminateChildWithDeadline(child: *std.process.Child, context: Context, timeout_ms: i64) !std.process.Child.Term {
    if (child.term) |term| return term;

    const deadline = Deadline.init(timeout_ms);
    std.posix.kill(child.id, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => return error.AlreadyTerminated,
        else => return err,
    };

    while (true) {
        const wait_result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_result.pid == child.id) return recordChildTerm(child, wait_result.status);

        const now_ms = std.time.milliTimestamp();
        if (deadline.expiredAt(now_ms)) {
            reportTimeout("server_shutdown", context, deadline, now_ms);
            std.posix.kill(child.id, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => return err,
            };
            const killed = std.posix.waitpid(child.id, 0);
            _ = recordChildTerm(child, killed.status);
            return error.HarnessDeadlineExceeded;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

pub fn closeChildStreams(child: *std.process.Child) void {
    if (child.stdin) |stdin| {
        stdin.close();
        child.stdin = null;
    }
    if (child.stdout) |stdout| {
        stdout.close();
        child.stdout = null;
    }
    if (child.stderr) |stderr| {
        stderr.close();
        child.stderr = null;
    }
}

fn deleteIfExists(path: []const u8) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn fileExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn recordChildTerm(child: *std.process.Child, status: u32) std.process.Child.Term {
    const term = termFromStatus(status);
    child.term = term;
    child.id = undefined;
    return term;
}

fn termFromStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}
