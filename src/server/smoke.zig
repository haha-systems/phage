const std = @import("std");
const zimq = @import("zimq");
const harness = @import("harness.zig");

const whole_harness_timeout_ms: i64 = 30_000;
const startup_timeout_ms: i64 = 5_000;
const shutdown_timeout_ms: i64 = 5_000;
const request_timeout_ms: i32 = 1_000;

const SmokeConfig = struct {
    server_exe: ?[]const u8 = null,
    db_path: ?[]const u8 = null,
};

const SmokeCase = struct {
    command: []const u8,
    expectation: Expectation,
};

const Expectation = union(enum) {
    exact: []const u8,
    err_prefix,
    contains_all: []const []const u8,
    contains_only_prefix_keys: PrefixExpectation,
};

const PrefixExpectation = struct {
    prefix: []const u8,
    present: []const []const u8,
    absent: []const []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(args[1..]);
    const server_exe = config.server_exe orelse return usageError("missing --server-exe PATH");
    const generated_db_path = if (config.db_path == null)
        try std.fmt.allocPrint(allocator, "/tmp/phage-server-smoke-{d}", .{std.time.nanoTimestamp()})
    else
        null;
    defer if (generated_db_path) |path| allocator.free(path);
    const db_path = config.db_path orelse generated_db_path.?;
    try validateTmpDbPath(db_path);

    try cleanupStoreFiles(db_path);
    defer cleanupStoreFiles(db_path) catch |err| {
        std.debug.print("warning: failed to clean smoke store {s}: {s}\n", .{ db_path, @errorName(err) });
    };

    const port = try chooseAvailablePort();
    const context = harness.Context{
        .name = "server-smoke",
        .db_path = db_path,
        .port = port,
        .clients = 1,
        .requests_per_client = smokeCaseCount(),
    };
    const whole_deadline = harness.Deadline.init(whole_harness_timeout_ms);
    const endpoint = try std.fmt.allocPrintSentinel(allocator, "tcp://127.0.0.1:{}", .{port}, 0);
    defer allocator.free(endpoint);
    const port_arg = try std.fmt.allocPrint(allocator, "{}", .{port});
    defer allocator.free(port_arg);

    var child = std.process.Child.init(&.{
        server_exe,
        "--port",
        port_arg,
        "--db-path",
        db_path,
        "--log-level",
        "err",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    var child_running = true;
    defer if (child_running) {
        if (harness.terminateChildWithDeadline(&child, context, shutdown_timeout_ms)) |term| {
            child_running = false;
            switch (term) {
                .Exited => |code| if (code != 0) std.debug.print("warning: server exited with code {} during smoke shutdown\n", .{code}),
                .Signal => |signal| std.debug.print("warning: server terminated by signal {} during smoke shutdown\n", .{signal}),
                else => std.debug.print("warning: server terminated unexpectedly: {}\n", .{term}),
            }
        } else |err| {
            child_running = false;
            std.debug.print("warning: failed to terminate server: {s}\n", .{@errorName(err)});
        }
    };

    try waitForServer(allocator, endpoint, context, whole_deadline);
    try runSmokeCases(allocator, endpoint, context, whole_deadline);

    const term = harness.terminateChildWithDeadline(&child, context, shutdown_timeout_ms) catch |err| {
        if (err == error.HarnessDeadlineExceeded or err == error.AlreadyTerminated) child_running = false;
        return err;
    };
    child_running = false;
    switch (term) {
        .Exited => |code| if (code != 0) return error.ServerShutdownFailed,
        else => return error.ServerShutdownFailed,
    }

    try cleanupStoreFiles(db_path);
    std.debug.print("server smoke passed endpoint={s} db_path={s}\n", .{ endpoint, db_path });
}

fn parseArgs(args: []const []const u8) !SmokeConfig {
    var config = SmokeConfig{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--server-exe")) {
            i += 1;
            if (i >= args.len) return usageError("--server-exe requires a value");
            config.server_exe = args[i];
        } else if (std.mem.eql(u8, arg, "--db-path")) {
            i += 1;
            if (i >= args.len) return usageError("--db-path requires a value");
            config.db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeUsage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            try writeUsage();
            return error.InvalidArgument;
        }
    }
    return config;
}

fn usageError(message: []const u8) error{InvalidArgument} {
    std.debug.print("error: {s}\n", .{message});
    writeUsage() catch {};
    return error.InvalidArgument;
}

fn writeUsage() !void {
    std.debug.print(
        \\Usage: phage-server-smoke --server-exe PATH [--db-path /tmp/phage-server-smoke]
        \\
        \\Starts the given phage-server executable on an available localhost port,
        \\exercises the documented MVP ZeroMQ commands, and removes /tmp store files.
        \\When --db-path is omitted, a unique /tmp/phage-server-smoke-* path is used.
        \\
    , .{});
}

fn chooseAvailablePort() !u16 {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

fn waitForServer(allocator: std.mem.Allocator, endpoint: [:0]const u8, context: harness.Context, whole_deadline: harness.Deadline) !void {
    const startup_deadline = harness.Deadline.init(startup_timeout_ms);
    while (true) {
        try whole_deadline.ensure("whole_harness", context);
        if (startup_deadline.expiredAt(std.time.milliTimestamp())) {
            harness.reportTimeout("server_startup", context, startup_deadline, std.time.milliTimestamp());
            return error.HarnessDeadlineExceeded;
        }
        if (request(allocator, endpoint, "PING", context, whole_deadline, false)) |response| {
            defer allocator.free(response);
            if (std.mem.eql(u8, response, "PONG")) return;
        } else |_| {}
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

fn smokeCaseCount() usize {
    return 15;
}

fn runSmokeCases(allocator: std.mem.Allocator, endpoint: [:0]const u8, context: harness.Context, deadline: harness.Deadline) !void {
    const all_keys = [_][]const u8{ "alpha", "user:1", "user:2" };
    const user_present = [_][]const u8{ "user:1", "user:2" };
    const user_absent = [_][]const u8{"alpha"};
    const cases = [_]SmokeCase{
        .{ .command = "PING", .expectation = .{ .exact = "PONG" } },
        .{ .command = "SET alpha one", .expectation = .{ .exact = "OK" } },
        .{ .command = "SET user:1 red", .expectation = .{ .exact = "OK" } },
        .{ .command = "SET user:2 blue", .expectation = .{ .exact = "OK" } },
        .{ .command = "GET alpha", .expectation = .{ .exact = "one" } },
        .{ .command = "KEYS *", .expectation = .{ .contains_all = &all_keys } },
        .{ .command = "KEYS user:.*", .expectation = .{ .contains_only_prefix_keys = .{ .prefix = "user:", .present = &user_present, .absent = &user_absent } } },
        .{ .command = "GET missing-key", .expectation = .err_prefix },
        .{ .command = "DELETE alpha", .expectation = .{ .exact = "OK" } },
        .{ .command = "GET alpha", .expectation = .err_prefix },
        .{ .command = "SET alias-key value", .expectation = .{ .exact = "OK" } },
        .{ .command = "DEL alias-key", .expectation = .{ .exact = "OK" } },
        .{ .command = "GET alias-key", .expectation = .err_prefix },
        .{ .command = "GET user:1 extra", .expectation = .err_prefix },
        .{ .command = "KEYS [", .expectation = .err_prefix },
    };

    for (cases) |case| {
        try deadline.ensure("whole_harness", context);
        const response = try request(allocator, endpoint, case.command, context, deadline, true);
        defer allocator.free(response);
        try assertResponse(case.command, response, case.expectation);
    }
}

fn request(allocator: std.mem.Allocator, endpoint: [:0]const u8, command: []const u8, context: harness.Context, deadline: harness.Deadline, report_operation_timeout: bool) ![]u8 {
    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const client: *zimq.Socket = try .init(ctx, .req);
    defer client.deinit();
    try client.set(.linger, @as(c_int, 0));
    try client.set(.sndtimeo, @as(c_int, request_timeout_ms));
    try client.set(.rcvtimeo, @as(c_int, request_timeout_ms));
    try deadline.ensure("client_connect", context);
    try client.connect(endpoint);

    try deadline.ensure("whole_harness", context);
    const send_deadline = harness.Deadline.init(@as(i64, request_timeout_ms));
    client.sendConstSlice(command, .{}) catch |err| {
        if (report_operation_timeout) harness.reportTimeout("request_send", context, send_deadline, std.time.milliTimestamp());
        return err;
    };
    try deadline.ensure("whole_harness", context);
    const receive_deadline = harness.Deadline.init(@as(i64, request_timeout_ms));
    var msg: zimq.Message = .empty();
    defer msg.deinit();
    _ = client.recvMsg(&msg, .{}) catch |err| {
        if (report_operation_timeout) harness.reportTimeout("response_receive", context, receive_deadline, std.time.milliTimestamp());
        return err;
    };
    return try allocator.dupe(u8, std.mem.trimRight(u8, msg.slice(), "\r\n"));
}

fn assertResponse(command: []const u8, response: []const u8, expectation: Expectation) !void {
    switch (expectation) {
        .exact => |expected| {
            if (!std.mem.eql(u8, expected, response)) return fail(command, response, "exact payload mismatch");
        },
        .err_prefix => {
            if (!std.mem.startsWith(u8, response, "ERR")) return fail(command, response, "expected ERR prefix");
        },
        .contains_all => |needles| {
            for (needles) |needle| {
                if (!responseContainsLine(response, needle)) return fail(command, response, "missing expected key in KEYS response");
            }
        },
        .contains_only_prefix_keys => |prefix_expectation| {
            for (prefix_expectation.present) |needle| {
                if (!responseContainsLine(response, needle)) return fail(command, response, "missing expected prefix key in KEYS response");
                if (!std.mem.startsWith(u8, needle, prefix_expectation.prefix)) return error.InvalidSmokeExpectation;
            }
            for (prefix_expectation.absent) |needle| {
                if (responseContainsLine(response, needle)) return fail(command, response, "unexpected non-prefix key in KEYS response");
            }
        },
    }
}

fn responseContainsLine(response: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

fn fail(command: []const u8, response: []const u8, reason: []const u8) error{UnexpectedResponse} {
    std.debug.print("smoke failed for command '{s}': {s}; response='{s}'\n", .{ command, reason, response });
    return error.UnexpectedResponse;
}

fn validateTmpDbPath(db_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(db_path) or !std.mem.startsWith(u8, db_path, "/tmp/") or db_path.len <= "/tmp/".len) {
        return usageError("--db-path must be an absolute /tmp/... file path");
    }

    var parts = std.mem.splitScalar(u8, db_path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            return usageError("--db-path must not contain traversal segments");
        }
    }
}

fn cleanupStoreFiles(db_path: []const u8) !void {
    try harness.cleanupStoreFiles(db_path);
}
