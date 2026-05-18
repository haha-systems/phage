const std = @import("std");
const zimq = @import("zimq");

const SustainedConfig = struct {
    server_exe: ?[]const u8 = null,
    db_path: ?[]const u8 = null,
    clients: usize = 2,
    requests: usize = 100,
};

const ClientWorker = struct {
    endpoint: [:0]const u8,
    client_id: usize,
    requests: usize,
    err: ?anyerror = null,
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
        try std.fmt.allocPrint(allocator, "/tmp/phage-server-sustained-smoke-{d}", .{std.time.nanoTimestamp()})
    else
        null;
    defer if (generated_db_path) |path| allocator.free(path);
    const db_path = config.db_path orelse generated_db_path.?;
    try validateTmpDbPath(db_path);

    try cleanupStoreFiles(db_path);
    defer cleanupStoreFiles(db_path) catch |err| {
        std.debug.print("warning: failed to clean sustained smoke store {s}: {s}\n", .{ db_path, @errorName(err) });
    };

    const port = try chooseAvailablePort();
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
        "info",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var server_stdout: std.ArrayList(u8) = .empty;
    defer server_stdout.deinit(allocator);
    var server_stderr: std.ArrayList(u8) = .empty;
    defer server_stderr.deinit(allocator);

    try child.spawn();
    var child_running = true;
    defer if (child_running) {
        if (child.kill()) |_| {
            child_running = false;
        } else |err| {
            child_running = false;
            std.debug.print("warning: failed to terminate server: {s}\n", .{@errorName(err)});
        }
    };

    try waitForServer(allocator, endpoint);
    try runSustainedClients(allocator, endpoint, config.clients, config.requests);

    try std.posix.kill(child.id, std.posix.SIG.TERM);
    try child.collectOutput(allocator, &server_stdout, &server_stderr, 1024 * 1024);
    const term = try child.wait();
    child_running = false;
    switch (term) {
        .Exited => |code| if (code != 0) return error.ServerShutdownFailed,
        else => return error.ServerShutdownFailed,
    }

    try assertShutdownMetricsLog(server_stderr.items);

    try cleanupStoreFiles(db_path);
    const total_requests = config.clients * config.requests;
    std.debug.print(
        "server sustained smoke passed endpoint={s} db_path={s} clients={} requests_per_client={} total_requests={} runtime_model=multi-client-serialized-req-rep shutdown_metrics_log_captured=true\n",
        .{ endpoint, db_path, config.clients, config.requests, total_requests },
    );
    writeShutdownLogSummary(server_stderr.items);
}

fn parseArgs(args: []const []const u8) !SustainedConfig {
    var config = SustainedConfig{};
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
        } else if (std.mem.eql(u8, arg, "--clients")) {
            i += 1;
            if (i >= args.len) return usageError("--clients requires a value");
            config.clients = std.fmt.parseInt(usize, args[i], 10) catch return usageError("--clients must be a positive integer");
        } else if (std.mem.eql(u8, arg, "--requests")) {
            i += 1;
            if (i >= args.len) return usageError("--requests requires a value");
            config.requests = std.fmt.parseInt(usize, args[i], 10) catch return usageError("--requests must be a positive integer");
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeUsage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            try writeUsage();
            return error.InvalidArgument;
        }
    }

    if (config.clients == 0 or config.clients > 32) return usageError("--clients must be from 1 through 32");
    if (config.requests == 0) return usageError("--requests must be at least 1");
    if (config.clients * config.requests > 2_000) return usageError("--clients * --requests must be at most 2000 for this bounded smoke");
    return config;
}

fn usageError(message: []const u8) error{InvalidArgument} {
    std.debug.print("error: {s}\n", .{message});
    writeUsage() catch {};
    return error.InvalidArgument;
}

fn writeUsage() !void {
    std.debug.print(
        \\Usage: phage-server-sustained-smoke --server-exe PATH [--db-path /tmp/phage-server-sustained-smoke] [--clients N] [--requests N]
        \\
        \\Starts the given phage-server executable on an available localhost port,
        \\opens N ZeroMQ REQ clients, sends repeated checked commands from each client,
        \\and verifies the current runtime model: multiple client connections are accepted,
        \\but the single REP loop serializes command execution.
        \\
        \\When --db-path is omitted, a unique /tmp/phage-server-sustained-smoke-* path is used.
        \\
    , .{});
}

fn chooseAvailablePort() !u16 {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

fn waitForServer(allocator: std.mem.Allocator, endpoint: [:0]const u8) !void {
    const deadline = std.time.milliTimestamp() + 5_000;
    while (std.time.milliTimestamp() < deadline) {
        if (request(allocator, endpoint, "PING")) |response| {
            defer allocator.free(response);
            if (std.mem.eql(u8, response, "PONG")) return;
        } else |_| {}
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    return error.ServerDidNotStart;
}

fn runSustainedClients(allocator: std.mem.Allocator, endpoint: [:0]const u8, clients: usize, requests: usize) !void {
    const workers = try allocator.alloc(ClientWorker, clients);
    defer allocator.free(workers);
    var threads = try allocator.alloc(std.Thread, clients);
    defer allocator.free(threads);

    for (workers, 0..) |*worker, client_id| {
        worker.* = .{ .endpoint = endpoint, .client_id = client_id, .requests = requests };
        threads[client_id] = try std.Thread.spawn(.{}, runClientWorker, .{ allocator, worker });
    }

    for (threads) |thread| thread.join();
    for (workers) |worker| {
        if (worker.err) |err| return err;
    }
}

fn runClientWorker(allocator: std.mem.Allocator, worker: *ClientWorker) void {
    runClientRequests(allocator, worker.endpoint, worker.client_id, worker.requests) catch |err| {
        worker.err = err;
        return;
    };
    worker.err = null;
}

fn runClientRequests(allocator: std.mem.Allocator, endpoint: [:0]const u8, client_id: usize, requests: usize) !void {
    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const client: *zimq.Socket = try .init(ctx, .req);
    defer client.deinit();
    try client.set(.linger, @as(c_int, 0));
    try client.set(.sndtimeo, @as(c_int, 1_000));
    try client.set(.rcvtimeo, @as(c_int, 1_000));
    try client.connect(endpoint);

    for (0..requests) |request_index| {
        var command_buf: [128]u8 = undefined;
        var expected_buf: [64]u8 = undefined;
        const pattern = request_index % 4;
        const command = switch (pattern) {
            0 => "PING",
            1 => try std.fmt.bufPrint(&command_buf, "SET sustained:{d}:{d} value-{d}-{d}", .{ client_id, request_index, client_id, request_index }),
            2 => try std.fmt.bufPrint(&command_buf, "GET sustained:{d}:{d}", .{ client_id, request_index - 1 }),
            else => try std.fmt.bufPrint(&command_buf, "DELETE sustained:{d}:{d}", .{ client_id, request_index - 2 }),
        };
        const expected = switch (pattern) {
            0 => "PONG",
            1 => "OK",
            2 => try std.fmt.bufPrint(&expected_buf, "value-{d}-{d}", .{ client_id, request_index - 1 }),
            else => "OK",
        };

        const response = try requestWithSocket(allocator, client, command);
        defer allocator.free(response);
        if (!std.mem.eql(u8, expected, response)) {
            std.debug.print("client {} request {} command '{s}' expected '{s}' got '{s}'\n", .{ client_id, request_index, command, expected, response });
            return error.UnexpectedResponse;
        }
    }
}

fn request(allocator: std.mem.Allocator, endpoint: [:0]const u8, command: []const u8) ![]u8 {
    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const client: *zimq.Socket = try .init(ctx, .req);
    defer client.deinit();
    try client.set(.linger, @as(c_int, 0));
    try client.set(.sndtimeo, @as(c_int, 500));
    try client.set(.rcvtimeo, @as(c_int, 500));
    try client.connect(endpoint);
    return requestWithSocket(allocator, client, command);
}

fn requestWithSocket(allocator: std.mem.Allocator, client: *zimq.Socket, command: []const u8) ![]u8 {
    try client.sendConstSlice(command, .{});
    var msg: zimq.Message = .empty();
    defer msg.deinit();
    _ = try client.recvMsg(&msg, .{});
    return try allocator.dupe(u8, std.mem.trimRight(u8, msg.slice(), "\r\n"));
}

fn assertShutdownMetricsLog(server_log: []const u8) !void {
    const shutdown_marker = "server lifecycle event=shutdown";
    if (!std.mem.containsAtLeast(u8, server_log, 1, shutdown_marker)) {
        std.debug.print("server stderr did not include shutdown lifecycle metrics; stderr='{s}'\n", .{server_log});
        return error.MissingShutdownMetricsLog;
    }
    const metric_markers = [_][]const u8{ "reads=", "writes=", "deletes=", "read_errors=", "write_errors=", "delete_errors=" };
    for (metric_markers) |marker| {
        if (!std.mem.containsAtLeast(u8, server_log, 1, marker)) {
            std.debug.print("server shutdown log missing marker '{s}'; stderr='{s}'\n", .{ marker, server_log });
            return error.MissingShutdownMetricsLog;
        }
    }
}

fn writeShutdownLogSummary(server_log: []const u8) void {
    const shutdown_marker = "server lifecycle event=shutdown";
    if (std.mem.indexOf(u8, server_log, shutdown_marker)) |start| {
        const line_end = std.mem.indexOfScalarPos(u8, server_log, start, '\n') orelse server_log.len;
        std.debug.print("captured_shutdown_log={s}\n", .{server_log[start..line_end]});
    }
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
    std.fs.cwd().deleteFile(db_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{db_path});
    std.fs.cwd().deleteFile(wal_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
