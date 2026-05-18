const std = @import("std");

const phage = @import("phage");
const zimq = @import("zimq");
const concurrent_runtime = @import("server/concurrent_runtime.zig");
const server_config = @import("server/config.zig");
const server_handler = @import("server/handler.zig");
const server_runtime = @import("server/runtime.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var thread_safe_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };

    const allocator = thread_safe_allocator.allocator();
    defer {
        const leaks = gpa.deinit();
        if (leaks == .leak) {
            std.debug.print("Memory leaks detected: {}\n", .{leaks});
        }
    }

    var stderr = std.fs.File.stderr().deprecatedWriter().any();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = server_config.parseArgSlice(args) catch |err| {
        try server_config.writeParseError(&stderr, err);
        try server_config.writeUsage(&stderr, "phage-server");
        return err;
    };

    if (config.help) {
        try server_config.writeUsage(&stderr, "phage-server");
        return;
    }

    std.debug.print("Starting Phage server with configuration:\n", .{});
    std.debug.print("  Port: {}\n", .{config.port});
    std.debug.print("  Database: {s}\n", .{config.db_path});
    std.debug.print("  Log Level: {}\n", .{config.log_level});
    std.debug.print("  Runtime: {s}\n", .{server_config.runtimeModelName(config.runtime)});
    std.debug.print("  Workers: {}\n", .{config.workers});
    std.log.info(
        "server lifecycle event=start port={} db_path={s} requested_log_level={} runtime_model={s} workers={}",
        .{ config.port, config.db_path, config.log_level, server_config.runtimeModelName(config.runtime), config.workers },
    );
    server_runtime.installProcessSignalHandlers();

    var store: phage.Phage = try .init(allocator, config.db_path);
    defer store.deinit();

    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    switch (config.runtime) {
        .serialized => try runSerialized(allocator, &store, ctx, config.port),
        .concurrent => try concurrent_runtime.run(allocator, &store, ctx, config.port, config.workers),
    }

    const snapshot = store.metrics.snapshot();
    std.log.info(
        "server lifecycle event=shutdown reads={} writes={} deletes={} read_errors={} write_errors={} delete_errors={} runtime_model={s} workers={}",
        .{ snapshot.reads, snapshot.writes, snapshot.deletes, snapshot.read_errors, snapshot.write_errors, snapshot.delete_errors, server_config.runtimeModelName(config.runtime), config.workers },
    );
}

fn runSerialized(allocator: std.mem.Allocator, store: *phage.Phage, ctx: *zimq.Context, port: u16) !void {
    const server_rep: *zimq.Socket = try .init(ctx, .rep);
    defer server_rep.deinit();

    const bind_address = try std.fmt.allocPrintSentinel(allocator, "tcp://*:{}", .{port}, 0);
    defer allocator.free(bind_address);

    try server_rep.bind(bind_address);
    std.log.info("server lifecycle event=bound address={s} runtime_model=multi-client-serialized-req-rep", .{bind_address});

    while (server_runtime.processShouldContinue()) {
        var buf: zimq.Message = .empty();
        defer buf.deinit();
        _ = server_rep.recvMsg(&buf, .{}) catch |err| {
            if (!server_runtime.processShouldContinue()) break;
            std.log.err("server receive error={s}", .{@errorName(err)});
            return err;
        };

        const response = try server_handler.handleRequest(allocator, store, buf.slice());
        defer response.deinit(allocator);
        try server_rep.sendSlice(response.bytes, .{});
    }
}
