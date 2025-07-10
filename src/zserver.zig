const std = @import("std");
const mem = @import("std").mem;

const phage = @import("phage");
const zimq = @import("zimq");

pub fn main() !void {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();
    const allocator_ptr = allocator.allocator();

    var store: phage.Phage = try .init(allocator_ptr, "phage_store");
    defer store.deinit();

    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const server_rep: *zimq.Socket = try .init(ctx, .rep);
    defer server_rep.deinit();

    try server_rep.bind("tcp://*:5555");

    var buf: zimq.Message = .empty();
    _ = try server_rep.recvMsg(&buf, .{});

    // Parse the command received from the client using Phage lib
    const command_str: []const u8 = buf.slice();
    // std.debug.print("Received: {s}\n", .{command_str});

    const command = phage.protocol.parseCommandSlice(command_str) catch |err| {
        std.debug.print("Error parsing command: {s}\n", .{@errorName(err)});
        const error_msg: []const u8 = "ERR Invalid command\n";
        try server_rep.sendConstSlice(error_msg, .{});
        return;
    };

    // Handle the command
    const result = phage.protocol.executeCommand(&store, command) catch |err| {
        std.debug.print("Error executing command: {s}\n", .{@errorName(err)});
        const error_msg: []const u8 = "ERR Execution failed\n";
        try server_rep.sendConstSlice(error_msg, .{});
        return;
    };

    try server_rep.sendConstSlice(result, .{});
    std.debug.print("Sent: {s}\n", .{result});
}
