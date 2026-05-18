const std = @import("std");

const phage = @import("phage");
const zimq = @import("zimq");
const server_config = @import("server/config.zig");
const server_runtime = @import("server/runtime.zig");

pub fn main() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator_ptr = allocator.allocator();
    defer {
        const leaks = allocator.deinit();
        if (leaks == .leak) {
            std.debug.print("Memory leaks detected: {}\n", .{leaks});
        }
    }

    var stderr = std.fs.File.stderr().deprecatedWriter().any();
    const args = try std.process.argsAlloc(allocator_ptr);
    defer std.process.argsFree(allocator_ptr, args);

    const config = server_config.parseArgSlice(args) catch |err| {
        try server_config.writeParseError(&stderr, err);
        try server_config.writeUsage(&stderr, "phage-server");
        return err;
    };

    if (config.help) {
        try server_config.writeUsage(&stderr, "phage-server");
        return;
    }

    // Set log level (this is a compile-time feature in Zig, but we can at least show what was requested)
    std.debug.print("Starting Phage server with configuration:\n", .{});
    std.debug.print("  Port: {}\n", .{config.port});
    std.debug.print("  Database: {s}\n", .{config.db_path});
    std.debug.print("  Log Level: {}\n", .{config.log_level});
    std.log.info("server lifecycle event=start port={} db_path={s} requested_log_level={}", .{ config.port, config.db_path, config.log_level });
    server_runtime.installProcessSignalHandlers();

    var store: phage.Phage = try .init(allocator_ptr, config.db_path);
    defer store.deinit();

    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const server_rep: *zimq.Socket = try .init(ctx, .rep);
    defer server_rep.deinit();

    // Use configured port
    const bind_address = try std.fmt.allocPrintSentinel(allocator_ptr, "tcp://*:{}", .{config.port}, 0);
    defer allocator_ptr.free(bind_address);

    try server_rep.bind(bind_address);
    std.log.info("server lifecycle event=bound address={s}", .{bind_address});

    while (server_runtime.processShouldContinue()) {
        var buf: zimq.Message = .empty();
        _ = server_rep.recvMsg(&buf, .{}) catch |err| {
            if (!server_runtime.processShouldContinue()) break;
            std.log.err("server receive error={s}", .{@errorName(err)});
            return err;
        };

        // Parse the command received from the client using Phage lib
        const command_str: []const u8 = buf.slice();
        // std.debug.print("Received: {s}\n", .{command_str});

        var command = phage.protocol.parseCommandSlice(command_str) catch |err| {
            std.debug.print("Error parsing command: {s}\n", .{@errorName(err)});
            const error_msg = switch (err) {
                error.InvalidCommand => "ERR Unknown command or invalid syntax\n",
                error.MissingKey => "ERR Missing key\n",
                error.MissingValue => "ERR Missing value\n",
                error.MissingPattern => "ERR Missing pattern\n",
                error.MissingBenchmarkOperations => "ERR Missing benchmark operation count\n",
                error.EmptyKey => "ERR Key cannot be empty\n",
                error.EmptyPattern => "ERR Pattern cannot be empty\n",
            };
            try server_rep.sendConstSlice(error_msg, .{});
            continue;
        };

        const result = command.execute(&store) catch |err| {
            std.debug.print("Error executing command: {s}\n", .{@errorName(err)});
            const error_msg = switch (err) {
                error.OutOfMemory => "ERR Server out of memory\n",
                error.InvalidPattern => "ERR Invalid pattern for KEYS command\n",
                error.InvalidRegex => "ERR Invalid regular expression pattern\n",
                else => "ERR Command execution failed\n",
            };
            try server_rep.sendConstSlice(error_msg, .{});
            continue;
        };

        switch (result.status) {
            .Ok => {
                // std.debug.print("Command executed successfully: {s}\n", .{result.payload()});
            },
            .Error => {
                const error_payload = try result.payloadToString(allocator_ptr);
                defer allocator_ptr.free(error_payload);
                std.debug.print("Command execution error: {s}\n", .{error_payload});
                const error_msg: []const u8 = "ERR Execution failed\n";
                try server_rep.sendConstSlice(error_msg, .{});
                continue;
            },
            else => {
                std.debug.print("Unexpected result status: {}\n", .{result.status});
                const error_msg: []const u8 = "ERR Unexpected result status\n";
                try server_rep.sendConstSlice(error_msg, .{});
                continue;
            },
        }

        const response_payload = try result.payloadToString(allocator_ptr);
        defer allocator_ptr.free(response_payload);
        try server_rep.sendConstSlice(response_payload, .{});
        std.debug.print("Sent: {}\n", .{result});
    }

    const snapshot = store.metrics.snapshot();
    std.log.info(
        "server lifecycle event=shutdown reads={} writes={} deletes={} read_errors={} write_errors={} delete_errors={}",
        .{ snapshot.reads, snapshot.writes, snapshot.deletes, snapshot.read_errors, snapshot.write_errors, snapshot.delete_errors },
    );
}
