const std = @import("std");
const mem = @import("std").mem;

const phage = @import("phage");
const zimq = @import("zimq");

pub fn main() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator_ptr = allocator.allocator();
    defer {
        const leaks = allocator.deinit();
        if (leaks == .leak) {
            std.debug.print("Memory leaks detected: {}\n", .{leaks});
        } else {
            std.debug.print("No memory leaks detected.\n", .{});
        }
    }

    var store: phage.Phage = try .init(allocator_ptr, "phage_store");
    defer store.deinit();

    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const server_rep: *zimq.Socket = try .init(ctx, .rep);
    defer server_rep.deinit();

    try server_rep.bind("tcp://*:5555");

    while (true) {
        var buf: zimq.Message = .empty();
        _ = try server_rep.recvMsg(&buf, .{});

        // Parse the command received from the client using Phage lib
        const command_str: []const u8 = buf.slice();
        // std.debug.print("Received: {s}\n", .{command_str});

        var command = phage.protocol.parseCommandSlice(command_str) catch |err| {
            std.debug.print("Error parsing command: {s}\n", .{@errorName(err)});
            const error_msg: []const u8 = "ERR Invalid command\n";
            try server_rep.sendConstSlice(error_msg, .{});
            continue;
        };

        const result = command.execute(&store) catch |err| {
            std.debug.print("Error executing command: {s}\n", .{@errorName(err)});
            const error_msg: []const u8 = "ERR Execution failed\n";
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
}
