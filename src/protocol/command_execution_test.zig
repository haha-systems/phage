const std = @import("std");
const phage = @import("phage");

const Phage = phage.Phage;
const protocol = phage.protocol;

const protocol_command_test_path = ".zig-cache/phage-tests/protocol_command.db";
const protocol_benchmark_test_path = ".zig-cache/phage-tests/protocol_benchmark.db";

fn cleanupProtocolTestPath(path: []const u8) void {
    std.posix.unlink(path) catch {};

    var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path}) catch return;
    std.posix.unlink(wal_path) catch {};

    var compact_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = std.fmt.bufPrint(&compact_path_buf, "{s}.compact.tmp", .{path}) catch return;
    std.posix.unlink(compact_path) catch {};
}

fn initProtocolTestStore(path: []const u8) !Phage {
    try std.fs.cwd().makePath(".zig-cache/phage-tests");
    cleanupProtocolTestPath(path);
    return try Phage.init(std.testing.allocator, path);
}

fn freeResultPayload(allocator: std.mem.Allocator, result: protocol.Result) void {
    switch (result.payload) {
        .Get => |get_result| allocator.free(@constCast(get_result.value)),
        .Keys => |keys_result| allocator.free(keys_result.keys),
        else => {},
    }
}

fn executeCommandResponse(allocator: std.mem.Allocator, store: *Phage, command_line: []const u8) ![]const u8 {
    var command = try protocol.parseCommandSlice(command_line);
    const result = try command.execute(store);
    defer freeResultPayload(allocator, result);
    return try result.payloadToString(allocator);
}

test "protocol command execution maps core commands to response payloads" {
    const allocator = std.testing.allocator;
    var store = try initProtocolTestStore(protocol_command_test_path);
    defer {
        store.deinit();
        cleanupProtocolTestPath(protocol_command_test_path);
    }

    var response = try executeCommandResponse(allocator, &store, "PING");
    try std.testing.expectEqualStrings("PONG", response);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "SET cmd:alpha one");
    try std.testing.expectEqualStrings("OK", response);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "GET cmd:alpha");
    try std.testing.expectEqualStrings("one", response);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "SET other two");
    try std.testing.expectEqualStrings("OK", response);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "KEYS *");
    try std.testing.expect(std.mem.indexOf(u8, response, "cmd:alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "other") != null);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "KEYS cmd:.*");
    try std.testing.expectEqualStrings("cmd:alpha", response);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "DELETE cmd:alpha");
    try std.testing.expectEqualStrings("OK", response);

    allocator.free(response);
    response = try executeCommandResponse(allocator, &store, "DEL other");
    try std.testing.expectEqualStrings("OK", response);
    allocator.free(response);
}

test "protocol benchmark command executes and reports benchmark response" {
    const allocator = std.testing.allocator;
    var store = try initProtocolTestStore(protocol_benchmark_test_path);
    defer {
        store.deinit();
        cleanupProtocolTestPath(protocol_benchmark_test_path);
    }

    const response = try executeCommandResponse(allocator, &store, "BENCHMARK 1");
    defer allocator.free(response);
    try std.testing.expect(std.mem.startsWith(u8, response, "Benchmark completed: 1 ops"));

    const value = try store.get("bench_key0");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("bench_value0", value);
}
