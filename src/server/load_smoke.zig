const std = @import("std");
const builtin = @import("builtin");
const zimq = @import("zimq");
const harness = @import("harness.zig");

const max_clients = 32;
const max_total_requests = 2_000;
const runtime_model = "multi-client-serialized-req-rep";
const whole_harness_timeout_ms: i64 = 60_000;
const startup_timeout_ms: i64 = 5_000;
const shutdown_timeout_ms: i64 = 5_000;
const request_timeout_ms: i32 = 1_000;

const OutputFormat = enum { human, json };
const CleanupStatus = enum { clean, artifacts_remaining };
const CommandKind = enum { ping, set, get, delete };

const LoadConfig = struct {
    server_exe: ?[]const u8 = null,
    db_path: ?[]const u8 = null,
    clients: usize = 2,
    requests: usize = 100,
    output_format: OutputFormat = .human,
};

const CommandCounts = struct {
    ping: usize = 0,
    set: usize = 0,
    get: usize = 0,
    delete: usize = 0,

    fn increment(self: *CommandCounts, kind: CommandKind) void {
        switch (kind) {
            .ping => self.ping += 1,
            .set => self.set += 1,
            .get => self.get += 1,
            .delete => self.delete += 1,
        }
    }

    fn add(self: *CommandCounts, other: CommandCounts) void {
        self.ping += other.ping;
        self.set += other.set;
        self.get += other.get;
        self.delete += other.delete;
    }
};

const LatencySummary = struct {
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
};

const LoadSummary = struct {
    clients: usize,
    requests_per_client: usize,
    total_requests: usize,
    runtime_model: []const u8,
    backend_status: []const u8,
    elapsed_ns: u64,
    requests_per_second: f64,
    command_counts: CommandCounts,
    error_count: usize,
    latency: LatencySummary,
    cleanup_status: CleanupStatus,
    shutdown_metrics_captured: bool,
};

const SummaryInput = struct {
    clients: usize,
    requests_per_client: usize,
    elapsed_ns: u64,
    latencies_ns: []u64,
    command_counts: CommandCounts,
    error_count: usize,
    cleanup_status: CleanupStatus,
    shutdown_metrics_captured: bool,
};

const ClientWorker = struct {
    endpoint: [:0]const u8,
    client_id: usize,
    requests: usize,
    latencies_ns: []u64,
    context: harness.Context,
    deadline: harness.Deadline,
    command_counts: CommandCounts = .{},
    error_count: usize = 0,
    err: ?anyerror = null,
};

const RequestSpec = struct {
    command: []const u8,
    expected: []const u8,
    kind: CommandKind,
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
        try std.fmt.allocPrint(allocator, "/tmp/phage-server-load-{d}", .{std.time.nanoTimestamp()})
    else
        null;
    defer if (generated_db_path) |path| allocator.free(path);
    const db_path = config.db_path orelse generated_db_path.?;
    try validateTmpDbPath(db_path);

    try cleanupStoreFiles(db_path);
    defer cleanupStoreFiles(db_path) catch |err| {
        std.debug.print("warning: failed to clean load smoke store {s}: {s}\n", .{ db_path, @errorName(err) });
    };

    const port = try chooseAvailablePort();
    const context = harness.Context{
        .name = "server-load",
        .db_path = db_path,
        .port = port,
        .clients = config.clients,
        .requests_per_client = config.requests,
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
        if (harness.terminateChildWithDeadline(&child, context, shutdown_timeout_ms)) |_| {
            child_running = false;
            harness.closeChildStreams(&child);
        } else |err| {
            child_running = false;
            harness.closeChildStreams(&child);
            std.debug.print("warning: failed to terminate server: {s}\n", .{@errorName(err)});
        }
    };

    try waitForServer(allocator, endpoint, context, whole_deadline);

    const start_ns = std.time.nanoTimestamp();
    var run_stats = try runLoadClients(allocator, endpoint, config.clients, config.requests, context, whole_deadline);
    defer run_stats.deinit(allocator);
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start_ns);

    const term = harness.terminateChildWithDeadline(&child, context, shutdown_timeout_ms) catch |err| {
        if (err == error.HarnessDeadlineExceeded or err == error.AlreadyTerminated) {
            child_running = false;
            harness.closeChildStreams(&child);
        }
        return err;
    };
    child_running = false;
    try child.collectOutput(allocator, &server_stdout, &server_stderr, 1024 * 1024);
    harness.closeChildStreams(&child);
    switch (term) {
        .Exited => |code| if (code != 0) return error.ServerShutdownFailed,
        else => return error.ServerShutdownFailed,
    }

    const shutdown_metrics_captured = try shutdownMetricsLogCaptured(server_stderr.items);
    try cleanupStoreFiles(db_path);
    const cleanup_status: CleanupStatus = if (try storeArtifactsClean(allocator, db_path)) .clean else .artifacts_remaining;
    if (cleanup_status != .clean) return error.StoreArtifactsRemaining;

    var summary = try buildSummary(.{
        .clients = config.clients,
        .requests_per_client = config.requests,
        .elapsed_ns = elapsed_ns,
        .latencies_ns = run_stats.latencies_ns,
        .command_counts = run_stats.command_counts,
        .error_count = run_stats.error_count,
        .cleanup_status = cleanup_status,
        .shutdown_metrics_captured = shutdown_metrics_captured,
    });
    summary.backend_status = backendStatusName();

    var stdout = std.fs.File.stdout().deprecatedWriter().any();
    switch (config.output_format) {
        .human => try writeHumanSummary(summary, endpoint, db_path, &stdout),
        .json => try writeJsonSummary(summary, &stdout),
    }
}

fn parseArgs(args: []const []const u8) !LoadConfig {
    var config = LoadConfig{};
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
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output_format = .json;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeUsage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            try writeUsage();
            return error.InvalidArgument;
        }
    }

    if (config.clients == 0 or config.clients > max_clients) return usageError("--clients must be from 1 through 32");
    if (config.requests == 0) return usageError("--requests must be at least 1");
    if (config.clients * config.requests > max_total_requests) return usageError("--clients * --requests must be at most 2000 for this bounded load smoke");
    if (config.db_path) |db_path| try validateTmpDbPath(db_path);
    return config;
}

fn usageError(message: []const u8) error{InvalidArgument} {
    if (!builtin.is_test) {
        std.debug.print("error: {s}\n", .{message});
        writeUsage() catch {};
    }
    return error.InvalidArgument;
}

fn writeUsage() !void {
    std.debug.print(
        \\Usage: phage-server-load --server-exe PATH [--db-path /tmp/phage-server-load] [--clients N] [--requests N] [--json]
        \\
        \\Starts the given phage-server executable on an available localhost port,
        \\opens N ZeroMQ REQ clients, sends a bounded PING/SET/GET/DELETE mix,
        \\and reports throughput plus p50/p95/p99 request latency for the current
        \\runtime model: multiple client connections are accepted, but the single REP
        \\loop serializes command execution.
        \\
        \\When --db-path is omitted, a unique /tmp/phage-server-load-* path is used.
        \\
    , .{});
}

const LoadRunStats = struct {
    latencies_ns: []u64,
    command_counts: CommandCounts,
    error_count: usize,

    fn deinit(self: *LoadRunStats, allocator: std.mem.Allocator) void {
        allocator.free(self.latencies_ns);
    }
};

fn runLoadClients(allocator: std.mem.Allocator, endpoint: [:0]const u8, clients: usize, requests: usize, context: harness.Context, deadline: harness.Deadline) !LoadRunStats {
    const workers = try allocator.alloc(ClientWorker, clients);
    defer allocator.free(workers);
    var threads = try allocator.alloc(std.Thread, clients);
    defer allocator.free(threads);

    for (workers, 0..) |*worker, client_id| {
        const latencies = try allocator.alloc(u64, requests);
        worker.* = .{
            .endpoint = endpoint,
            .client_id = client_id,
            .requests = requests,
            .latencies_ns = latencies,
            .context = context,
            .deadline = deadline,
        };
        threads[client_id] = try std.Thread.spawn(.{}, runClientWorker, .{ allocator, worker });
    }
    defer for (workers) |worker| allocator.free(worker.latencies_ns);

    for (threads) |thread| thread.join();

    const total_requests = clients * requests;
    const all_latencies = try allocator.alloc(u64, total_requests);
    var command_counts = CommandCounts{};
    var error_count: usize = 0;
    var offset: usize = 0;
    for (workers) |worker| {
        command_counts.add(worker.command_counts);
        error_count += worker.error_count;
        if (worker.err) |err| return err;
        @memcpy(all_latencies[offset .. offset + worker.latencies_ns.len], worker.latencies_ns);
        offset += worker.latencies_ns.len;
    }

    return .{ .latencies_ns = all_latencies, .command_counts = command_counts, .error_count = error_count };
}

fn runClientWorker(allocator: std.mem.Allocator, worker: *ClientWorker) void {
    runClientRequests(allocator, worker) catch |err| {
        worker.err = err;
        return;
    };
    worker.err = null;
}

fn runClientRequests(allocator: std.mem.Allocator, worker: *ClientWorker) !void {
    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const client: *zimq.Socket = try .init(ctx, .req);
    defer client.deinit();
    try client.set(.linger, @as(c_int, 0));
    try client.set(.sndtimeo, @as(c_int, request_timeout_ms));
    try client.set(.rcvtimeo, @as(c_int, request_timeout_ms));
    try worker.deadline.ensure("client_connect", worker.context);
    try client.connect(worker.endpoint);

    for (0..worker.requests) |request_index| {
        try worker.deadline.ensure("whole_harness", worker.context);
        var command_buf: [128]u8 = undefined;
        var expected_buf: [64]u8 = undefined;
        const spec = try requestSpec(worker.client_id, request_index, &command_buf, &expected_buf);
        worker.command_counts.increment(spec.kind);

        const start_ns = std.time.nanoTimestamp();
        const response = requestWithSocket(allocator, client, spec.command, worker.context, worker.deadline, true) catch |err| {
            worker.error_count += 1;
            return err;
        };
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start_ns);
        worker.latencies_ns[request_index] = elapsed_ns;
        defer allocator.free(response);
        if (!std.mem.eql(u8, spec.expected, response)) {
            worker.error_count += 1;
            std.debug.print("client {} request {} command '{s}' expected '{s}' got '{s}'\n", .{ worker.client_id, request_index, spec.command, spec.expected, response });
            return error.UnexpectedResponse;
        }
    }
}

fn requestSpec(client_id: usize, request_index: usize, command_buf: []u8, expected_buf: []u8) !RequestSpec {
    const pattern = request_index % 4;
    return switch (pattern) {
        0 => .{ .command = "PING", .expected = "PONG", .kind = .ping },
        1 => .{
            .command = try std.fmt.bufPrint(command_buf, "SET load:{d}:{d} value-{d}-{d}", .{ client_id, request_index, client_id, request_index }),
            .expected = "OK",
            .kind = .set,
        },
        2 => .{
            .command = try std.fmt.bufPrint(command_buf, "GET load:{d}:{d}", .{ client_id, request_index - 1 }),
            .expected = try std.fmt.bufPrint(expected_buf, "value-{d}-{d}", .{ client_id, request_index - 1 }),
            .kind = .get,
        },
        else => .{
            .command = try std.fmt.bufPrint(command_buf, "DELETE load:{d}:{d}", .{ client_id, request_index - 2 }),
            .expected = "OK",
            .kind = .delete,
        },
    };
}

fn buildSummary(input: SummaryInput) !LoadSummary {
    if (input.latencies_ns.len == 0) return error.InvalidArgument;
    std.mem.sort(u64, input.latencies_ns, {}, std.sort.asc(u64));
    const total_requests = input.clients * input.requests_per_client;
    return .{
        .clients = input.clients,
        .requests_per_client = input.requests_per_client,
        .total_requests = total_requests,
        .runtime_model = runtime_model,
        .backend_status = backendStatusName(),
        .elapsed_ns = input.elapsed_ns,
        .requests_per_second = throughput(total_requests, input.elapsed_ns),
        .command_counts = input.command_counts,
        .error_count = input.error_count,
        .latency = .{
            .p50_ns = percentileNearestRank(input.latencies_ns, 50),
            .p95_ns = percentileNearestRank(input.latencies_ns, 95),
            .p99_ns = percentileNearestRank(input.latencies_ns, 99),
        },
        .cleanup_status = input.cleanup_status,
        .shutdown_metrics_captured = input.shutdown_metrics_captured,
    };
}

fn throughput(total_requests: usize, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0.0;
    return @as(f64, @floatFromInt(total_requests)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
}

fn percentileNearestRank(sorted_samples: []const u64, percentile: usize) u64 {
    std.debug.assert(sorted_samples.len > 0);
    const rank_numerator = percentile * sorted_samples.len;
    var rank = rank_numerator / 100;
    if (rank_numerator % 100 != 0) rank += 1;
    if (rank == 0) rank = 1;
    const index = @min(rank - 1, sorted_samples.len - 1);
    return sorted_samples[index];
}

fn writeHumanSummary(summary: LoadSummary, endpoint: []const u8, db_path: []const u8, writer: *std.io.AnyWriter) !void {
    try writer.print("server load smoke passed endpoint={s} db_path={s}\n", .{ endpoint, db_path });
    try writer.print("clients={} requests_per_client={} total_requests={} runtime_model={s}\n", .{ summary.clients, summary.requests_per_client, summary.total_requests, summary.runtime_model });
    try writer.print("backend_status={s} elapsed_ms={d:.2} throughput_requests_per_sec={d:.2}\n", .{ summary.backend_status, nsToMs(summary.elapsed_ns), summary.requests_per_second });
    try writer.print("command_counts ping={} set={} get={} delete={} errors={}\n", .{ summary.command_counts.ping, summary.command_counts.set, summary.command_counts.get, summary.command_counts.delete, summary.error_count });
    try writer.print("latency_us p50={d:.2} p95={d:.2} p99={d:.2}\n", .{ nsToUs(summary.latency.p50_ns), nsToUs(summary.latency.p95_ns), nsToUs(summary.latency.p99_ns) });
    try writer.print("cleanup_status={s} shutdown_metrics_log_captured={}\n", .{ cleanupStatusName(summary.cleanup_status), summary.shutdown_metrics_captured });
}

fn writeJsonSummary(summary: LoadSummary, writer: *std.io.AnyWriter) !void {
    try writer.writeAll("{");
    try writer.print("\"clients\":{d},\"requests_per_client\":{d},\"total_requests\":{d}", .{ summary.clients, summary.requests_per_client, summary.total_requests });
    try writer.writeAll(",\"request_mix\":{");
    try writer.print("\"ping\":{d},\"set\":{d},\"get\":{d},\"delete\":{d}", .{ summary.command_counts.ping, summary.command_counts.set, summary.command_counts.get, summary.command_counts.delete });
    try writer.writeAll("},\"runtime_model\":\"");
    try writer.writeAll(summary.runtime_model);
    try writer.writeAll("\",\"backend_status\":\"");
    try writer.writeAll(summary.backend_status);
    try writer.writeAll("\"");
    try writer.print(",\"elapsed_ns\":{d},\"elapsed_ms\":{d:.2}", .{ summary.elapsed_ns, nsToMs(summary.elapsed_ns) });
    try writer.writeAll(",\"throughput\":{");
    try writer.print("\"requests_per_second\":{d:.2}", .{summary.requests_per_second});
    try writer.writeAll("},\"latency_us\":{");
    try writer.print("\"p50\":{d:.2},\"p95\":{d:.2},\"p99\":{d:.2}", .{ nsToUs(summary.latency.p50_ns), nsToUs(summary.latency.p95_ns), nsToUs(summary.latency.p99_ns) });
    try writer.writeAll("},\"errors\":{");
    try writer.print("\"total\":{d}", .{summary.error_count});
    try writer.writeAll("},\"cleanup_status\":\"");
    try writer.writeAll(cleanupStatusName(summary.cleanup_status));
    try writer.writeAll("\"");
    try writer.print(",\"shutdown_metrics_log_captured\":{}", .{summary.shutdown_metrics_captured});
    try writer.writeAll("}\n");
}

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000.0;
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn backendStatusName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-io-uring-intended",
        .macos => "macos-posix-fallback",
        else => "host-default-posix-fallback",
    };
}

fn cleanupStatusName(status: CleanupStatus) []const u8 {
    return switch (status) {
        .clean => "clean",
        .artifacts_remaining => "artifacts_remaining",
    };
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
    return requestWithSocket(allocator, client, command, context, deadline, report_operation_timeout);
}

fn requestWithSocket(allocator: std.mem.Allocator, client: *zimq.Socket, command: []const u8, context: harness.Context, deadline: harness.Deadline, report_operation_timeout: bool) ![]u8 {
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

fn shutdownMetricsLogCaptured(server_log: []const u8) !bool {
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
    return true;
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

fn storeArtifactsClean(allocator: std.mem.Allocator, db_path: []const u8) !bool {
    return try harness.storeArtifactsClean(allocator, db_path);
}

test "load args support bounded JSON measurements" {
    const config = try parseArgs(&.{ "--server-exe", "zig-out/bin/phage-server", "--db-path", "/tmp/phage-load-test", "--clients", "2", "--requests", "100", "--json" });

    try std.testing.expectEqualStrings("zig-out/bin/phage-server", config.server_exe.?);
    try std.testing.expectEqualStrings("/tmp/phage-load-test", config.db_path.?);
    try std.testing.expectEqual(@as(usize, 2), config.clients);
    try std.testing.expectEqual(@as(usize, 100), config.requests);
    try std.testing.expectEqual(OutputFormat.json, config.output_format);
}

test "load args reject unbounded request shapes" {
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "--clients", "33", "--requests", "1" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "--clients", "2", "--requests", "1001" }));
}

test "load db path validation rejects unsafe generated paths" {
    try validateTmpDbPath("/tmp/phage-load-safe");
    try std.testing.expectError(error.InvalidArgument, validateTmpDbPath("relative.db"));
    try std.testing.expectError(error.InvalidArgument, validateTmpDbPath("/var/tmp/phage-load"));
    try std.testing.expectError(error.InvalidArgument, validateTmpDbPath("/tmp/../phage-load"));
}

test "load summary computes throughput percentiles and command counts" {
    var latencies = [_]u64{ 5_000, 1_000, 9_000, 2_000 };
    const command_counts = CommandCounts{ .ping = 1, .set = 1, .get = 1, .delete = 1 };
    const summary = try buildSummary(.{
        .clients = 2,
        .requests_per_client = 2,
        .elapsed_ns = 2 * std.time.ns_per_s,
        .latencies_ns = &latencies,
        .command_counts = command_counts,
        .error_count = 0,
        .cleanup_status = .clean,
        .shutdown_metrics_captured = true,
    });

    try std.testing.expectEqual(@as(usize, 4), summary.total_requests);
    try std.testing.expectEqual(@as(u64, 2_000), summary.latency.p50_ns);
    try std.testing.expectEqual(@as(u64, 9_000), summary.latency.p95_ns);
    try std.testing.expectEqual(@as(u64, 9_000), summary.latency.p99_ns);
    try std.testing.expectEqual(@as(f64, 2.0), summary.requests_per_second);
    try std.testing.expectEqual(@as(usize, 1), summary.command_counts.get);
}

test "load JSON output is parseable and names measurement fields" {
    const summary = LoadSummary{
        .clients = 2,
        .requests_per_client = 50,
        .total_requests = 100,
        .runtime_model = "multi-client-serialized-req-rep",
        .backend_status = "macos-posix-fallback-or-host-default",
        .elapsed_ns = 1_000_000_000,
        .requests_per_second = 100.0,
        .command_counts = .{ .ping = 25, .set = 25, .get = 25, .delete = 25 },
        .error_count = 0,
        .latency = .{ .p50_ns = 1_000, .p95_ns = 2_000, .p99_ns = 3_000 },
        .cleanup_status = .clean,
        .shutdown_metrics_captured = true,
    };
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try writeJsonSummary(summary, &writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 100), root.get("total_requests").?.integer);
    try std.testing.expectEqualStrings("multi-client-serialized-req-rep", root.get("runtime_model").?.string);
    try std.testing.expect(root.get("throughput").?.object.get("requests_per_second") != null);
    try std.testing.expect(root.get("latency_us").?.object.get("p95") != null);
    try std.testing.expectEqualStrings("clean", root.get("cleanup_status").?.string);
}

test "harness timeout report names actionable load context" {
    const context = harness.Context{
        .name = "server-load",
        .db_path = "/tmp/phage-load-timeout-test",
        .port = 49152,
        .clients = 2,
        .requests_per_client = 100,
    };
    const deadline = harness.Deadline{ .started_ms = 1_000, .deadline_ms = 6_000 };
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try harness.writeTimeoutReport(&writer, "response_receive", context, deadline, 6_250);

    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "error: server harness timeout"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "phase=response_receive"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "harness=server-load"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "clients=2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "requests_per_client=100"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "port=49152"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "db_path=/tmp/phage-load-timeout-test"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "elapsed_ms=5250"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output.items, 1, "deadline_ms=5000"));
}

test "harness cleanup removes compact temp artifact with db and wal" {
    const db_path = "/tmp/phage-load-cleanup-test";
    try std.fs.cwd().writeFile(.{ .sub_path = db_path, .data = "db" });
    try std.fs.cwd().writeFile(.{ .sub_path = "/tmp/phage-load-cleanup-test.wal", .data = "wal" });
    try std.fs.cwd().writeFile(.{ .sub_path = "/tmp/phage-load-cleanup-test.compact.tmp", .data = "compact" });

    try harness.cleanupStoreFiles(db_path);

    try std.testing.expect(!(try harness.storeArtifactsExist(std.testing.allocator, db_path)));
}
