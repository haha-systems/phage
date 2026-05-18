const std = @import("std");
const phage = @import("phage");

const Phage = phage.Phage;
const protocol = phage.protocol;

pub const Response = struct {
    bytes: []const u8,
    owned: bool = false,

    pub fn borrowed(bytes: []const u8) Response {
        return .{ .bytes = bytes, .owned = false };
    }

    /// Wraps response bytes that must be released with the same allocator later
    /// passed to `deinit`.
    pub fn ownedSlice(bytes: []const u8) Response {
        return .{ .bytes = bytes, .owned = true };
    }

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bytes);
    }
};

fn parseErrorResponse(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidCommand => "ERR Unknown command or invalid syntax\n",
        error.MissingKey => "ERR Missing key\n",
        error.MissingValue => "ERR Missing value\n",
        error.MissingPattern => "ERR Missing pattern\n",
        error.MissingBenchmarkOperations => "ERR Missing benchmark operation count\n",
        error.EmptyKey => "ERR Key cannot be empty\n",
        error.EmptyPattern => "ERR Pattern cannot be empty\n",
        else => "ERR Unknown command or invalid syntax\n",
    };
}

fn executionErrorResponse(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "ERR Server out of memory\n",
        error.InvalidPattern => "ERR Invalid pattern for KEYS command\n",
        error.InvalidRegex => "ERR Invalid regular expression pattern\n",
        else => "ERR Command execution failed\n",
    };
}

fn freeKeysResult(allocator: std.mem.Allocator, keys: [][]const u8) void {
    if (keys.len > 0) allocator.free(keys);
}

fn responseFromResult(allocator: std.mem.Allocator, result: protocol.Result) !Response {
    switch (result.status) {
        .Ok => {},
        .Error => {
            const error_payload = try result.payloadToString(allocator);
            defer allocator.free(error_payload);
            std.debug.print("Command execution error: {s}\n", .{error_payload});
            return Response.borrowed("ERR Execution failed\n");
        },
        else => {
            std.debug.print("Unexpected result status: {}\n", .{result.status});
            return Response.borrowed("ERR Unexpected result status\n");
        },
    }

    return switch (result.payload) {
        .Set => Response.borrowed("OK"),
        .Delete => Response.borrowed("OK"),
        .Ping => |ping_result| Response.borrowed(ping_result.response),
        .Get => |get_result| Response.ownedSlice(get_result.value),
        .Keys => |keys_result| keys_response: {
            if (keys_result.keys.len == 0) break :keys_response Response.borrowed("(empty)");
            defer freeKeysResult(allocator, keys_result.keys);
            break :keys_response Response.ownedSlice(try std.mem.join(allocator, "\n", keys_result.keys));
        },
        .Benchmark, .Unknown => Response.ownedSlice(try result.payloadToString(allocator)),
    };
}

/// Parses and executes one server request against `store`, returning the exact
/// response bytes the serialized REP loop sends for the current text protocol.
///
/// Parsed command payloads borrow from `request`, so callers must keep the
/// request bytes alive until this function returns. Returned bytes remain valid
/// until `Response.deinit` is called; static protocol responses are borrowed and
/// allocated GET/KEYS/BENCHMARK responses are owned by the Response.
pub fn handleRequest(allocator: std.mem.Allocator, store: *Phage, request: []const u8) !Response {
    var command = protocol.parseCommandSlice(request) catch |err| {
        std.debug.print("Error parsing command: {s}\n", .{@errorName(err)});
        return Response.borrowed(parseErrorResponse(err));
    };

    const result = command.execute(store) catch |err| {
        std.debug.print("Error executing command: {s}\n", .{@errorName(err)});
        return Response.borrowed(executionErrorResponse(err));
    };

    return try responseFromResult(allocator, result);
}

const handler_test_path = ".zig-cache/phage-tests/server_handler.db";
const handler_benchmark_test_path = ".zig-cache/phage-tests/server_handler_benchmark.db";

fn cleanupHandlerTestPath(path: []const u8) void {
    std.posix.unlink(path) catch {};

    var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path}) catch return;
    std.posix.unlink(wal_path) catch {};

    var compact_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = std.fmt.bufPrint(&compact_path_buf, "{s}.compact.tmp", .{path}) catch return;
    std.posix.unlink(compact_path) catch {};
}

fn initHandlerTestStore(path: []const u8) !Phage {
    try std.fs.cwd().makePath(".zig-cache/phage-tests");
    cleanupHandlerTestPath(path);
    return try Phage.init(std.testing.allocator, path);
}

fn expectHandlerResponse(store: *Phage, request: []const u8, expected: []const u8) !void {
    const response = try handleRequest(std.testing.allocator, store, request);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, response.bytes);
}

fn expectHandlerResponseContainsLine(store: *Phage, request: []const u8, expected_line: []const u8) !void {
    const response = try handleRequest(std.testing.allocator, store, request);
    defer response.deinit(std.testing.allocator);

    var lines = std.mem.splitScalar(u8, response.bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, expected_line, line)) return;
    }

    std.debug.print("handler response for '{s}' did not contain line '{s}': '{s}'\n", .{ request, expected_line, response.bytes });
    return error.MissingExpectedLine;
}

test "server handler maps core command requests to wire-compatible responses" {
    var store = try initHandlerTestStore(handler_test_path);
    defer {
        store.deinit();
        cleanupHandlerTestPath(handler_test_path);
    }

    try expectHandlerResponse(&store, "PING", "PONG");
    try expectHandlerResponse(&store, "SET handler:alpha one", "OK");
    try expectHandlerResponse(&store, "GET handler:alpha", "one");
    try expectHandlerResponse(&store, "SET handler:beta two", "OK");
    try expectHandlerResponseContainsLine(&store, "KEYS handler:.*", "handler:alpha");
    try expectHandlerResponseContainsLine(&store, "KEYS handler:.*", "handler:beta");
    try expectHandlerResponse(&store, "DELETE handler:alpha", "OK");
    try expectHandlerResponse(&store, "GET handler:alpha", "ERR Command execution failed\n");
    try expectHandlerResponse(&store, "DEL handler:beta", "OK");
    try expectHandlerResponse(&store, "GET handler:beta", "ERR Command execution failed\n");
    try expectHandlerResponse(&store, "KEYS handler:.*", "(empty)");
}

test "server handler preserves parse and execution error responses" {
    var store = try initHandlerTestStore(handler_test_path);
    defer {
        store.deinit();
        cleanupHandlerTestPath(handler_test_path);
    }

    try expectHandlerResponse(&store, "BOGUS", "ERR Unknown command or invalid syntax\n");
    try expectHandlerResponse(&store, "PING extra", "ERR Unknown command or invalid syntax\n");
    try expectHandlerResponse(&store, "SET", "ERR Missing key\n");
    try expectHandlerResponse(&store, "SET key", "ERR Missing value\n");
    try expectHandlerResponse(&store, "GET", "ERR Missing key\n");
    try expectHandlerResponse(&store, "DELETE", "ERR Missing key\n");
    try expectHandlerResponse(&store, "KEYS", "ERR Missing pattern\n");
    try expectHandlerResponse(&store, "BENCHMARK", "ERR Missing benchmark operation count\n");

    try expectHandlerResponse(&store, "SET invalid-pattern-seed value", "OK");
    try expectHandlerResponse(&store, "KEYS [", "ERR Invalid regular expression pattern\n");
}

test "server handler executes BENCHMARK 1 and returns the existing response prefix" {
    var store = try initHandlerTestStore(handler_benchmark_test_path);
    defer {
        store.deinit();
        cleanupHandlerTestPath(handler_benchmark_test_path);
    }

    const response = try handleRequest(std.testing.allocator, &store, "BENCHMARK 1");
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, response.bytes, "Benchmark completed: 1 ops"));

    const value = try store.get("bench_key0");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("bench_value0", value);
}
