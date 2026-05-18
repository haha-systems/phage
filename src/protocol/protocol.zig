const std = @import("std");

pub const commands = @import("commands.zig");
const Phage = @import("phage").Phage;

/// # Phage wire protocol
///
/// This module defines the wire protocol for the Phage server.
/// The protocol is a simple text-based protocol that uses
/// newline-separated commands and responses, similar to the Redis protocol.
///
/// ## Examples
///
/// The basic command format is as follows:
///
/// `[command] [args...] [newline]`
///
/// - [command] must always be the first word in the line.
/// - [args...] are optional arguments that follow the command.
/// - [newline] is a newline character (`\n`) that terminates the command.
///
/// ### PING / PONG
///
/// ```
/// Client: PING\n (5 bytes)
/// Server: PONG\n (5 bytes)
/// ```
///
/// ### GET / SET / DELETE
///
/// ```
/// Client: GET key\n (8 bytes)
/// Server: value\n (6 bytes)
/// Client: SET key value\n (12 bytes)
/// Server: OK\n (3 bytes)
/// Client: DELETE key\n (12 bytes)
/// Server: OK\n (3 bytes)
/// ```
///
/// # Note
/// For simplicity, we use a global atomic counter to generate unique command IDs.
/// Although the ID won't be unique across multiple instances of the server,
/// it will be unique within a single instance, which is sufficient for our use case.
/// This will reset when the server restarts.
var next_command_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Status defines the status of a command.
pub const Status = enum(i8) {
    Ok = 0,
    Error = 1,
    NotFound = 2,
    InvalidCommand = 3,
    Unknown = -1,
};

// CommandType defines a set of valid commands that can be sent to the server.
pub const CommandType = enum(i8) {
    Set = 1,
    Get = 2,
    Delete = 3,
    Keys = 4,
    Ping = 5,
    Benchmark = 6,
    Unknown = -1,
};

// Command defines the structure of a command sent to the server.
pub const Command = struct {
    id: u32,
    command: CommandType,
    payload: Payload,
    result: ?*Result = null,

    /// Creates a new command with the given ID and command type,
    /// initializing the payload to `Payload.Unknown`.
    pub fn init(command: CommandType) Command {
        return Command{
            .id = nextCommandId(),
            .command = command,
            .payload = Payload.Unknown,
            .result = null,
        };
    }

    /// Returns the command name as a slice.
    pub fn name(self: Command) []const u8 {
        return switch (self.command) {
            .Set => "SET",
            .Get => "GET",
            .Delete => "DELETE",
            .Keys => "KEYS",
            .Ping => "PING",
            .Benchmark => "BENCHMARK",
            .Unknown => "UNKNOWN",
        };
    }

    /// Creates a new Set command with the given ID and key-value pair,
    /// initializing the payload to a SetRequest with the given key and value.
    pub fn set(key: []const u8, value: []const u8) Command {
        return Command{
            .id = nextCommandId(),
            .command = CommandType.Set,
            .payload = .{
                .Set = SetRequest{
                    .key = key,
                    .value = value,
                },
            },
            .result = null,
        };
    }

    /// Creates a new Get command with the given ID and key,
    /// initializing the payload to a GetRequest with the given key.
    pub fn get(key: []const u8) Command {
        return Command{
            .id = nextCommandId(),
            .command = CommandType.Get,
            .payload = .{
                .Get = GetRequest{
                    .key = key,
                },
            },
            .result = null,
        };
    }

    /// Creates a new Delete command with the given ID and key,
    /// initializing the payload to a DeleteRequest with the given key.
    pub fn delete(key: []const u8) Command {
        return Command{
            .id = nextCommandId(),
            .command = CommandType.Delete,
            .payload = .{
                .Delete = DeleteRequest{
                    .key = key,
                },
            },
            .result = null,
        };
    }

    /// Creates a new Ping command with the given ID,
    /// initializing the payload to a PingRequest.
    /// Note that this is essentially a no-op command that just checks if the server is alive.
    pub fn ping() Command {
        return Command{
            .id = nextCommandId(),
            .command = CommandType.Ping,
            .payload = .{
                .Ping = PingRequest{},
            },
            .result = null,
        };
    }

    /// Creates a new Keys command with the given ID and pattern,
    /// initializing the payload to a KeysRequest with the given pattern.
    pub fn keys(pattern: []const u8) Command {
        return Command{
            .id = nextCommandId(),
            .command = CommandType.Keys,
            .payload = .{
                .Keys = KeysRequest{
                    .pattern = pattern,
                },
            },
            .result = null,
        };
    }

    /// Creates a new Unknown command with the given ID.
    /// Note that this is essentially a no-op command.
    pub fn unknown() Command {
        return Command{
            .id = nextCommandId(),
            .command = CommandType.Unknown,
            .payload = .{
                .Unknown = {},
            },
            .result = null,
        };
    }

    /// Executes the command using the given Phage store.
    /// Returns the result of the command execution.
    pub fn execute(self: *Command, store: *Phage) !Result {
        switch (self.command) {
            .Set => {
                const request = self.payload.Set;
                const result = try request.execute(store);
                return Result{
                    .id = self.id,
                    .status = Status.Ok,
                    .payload = ResultPayload{ .Set = result },
                };
            },
            .Get => {
                const request = self.payload.Get;
                const value = try request.execute(store);
                return Result{
                    .id = self.id,
                    .status = Status.Ok,
                    .payload = ResultPayload{ .Get = GetResult{ .value = value } },
                };
            },
            .Delete => {
                const request = self.payload.Delete;
                const success = try store.delete(request.key);
                return Result{
                    .id = self.id,
                    .status = Status.Ok,
                    .payload = ResultPayload{ .Delete = DeleteResult{ .success = success } },
                };
            },
            .Keys => {
                const request = self.payload.Keys;
                const result = try request.execute(store);
                return Result{
                    .id = self.id,
                    .status = Status.Ok,
                    .payload = ResultPayload{ .Keys = result },
                };
            },
            .Ping => {
                return Result{
                    .id = self.id,
                    .status = Status.Ok,
                    .payload = ResultPayload{ .Ping = PingResult{ .response = "PONG" } },
                };
            },
            .Benchmark => {
                const request = self.payload.Benchmark;
                const result = try request.execute(store);
                return Result{
                    .id = self.id,
                    .status = Status.Ok,
                    .payload = ResultPayload{ .Benchmark = result },
                };
            },
            .Unknown => {
                return Result{
                    .id = self.id,
                    .status = Status.Error,
                    .payload = ResultPayload{ .Unknown = UnknownResult{ .errors = "Unknown command" } },
                };
            },
        }
    }
};

// Payload defines the structure of the payload of a command.
pub const Payload = union(enum) {
    Set: SetRequest,
    Get: GetRequest,
    Delete: DeleteRequest,
    Keys: KeysRequest,
    Ping: PingRequest,
    Benchmark: BenchmarkRequest,
    Unknown,
};

// Result defines the structure of a command result sent from the server.
pub const Result = struct {
    id: u32,
    status: Status,
    payload: ResultPayload,

    /// Converts the result payload to a string that can be sent over the wire.
    pub fn payloadToString(self: Result, allocator: std.mem.Allocator) ![]const u8 {
        switch (self.payload) {
            .Set => {
                return try std.fmt.allocPrint(allocator, "OK", .{});
            },
            .Get => |get_result| {
                return try std.fmt.allocPrint(allocator, "{s}", .{get_result.value});
            },
            .Delete => {
                return try std.fmt.allocPrint(allocator, "OK", .{});
            },
            .Keys => |keys_result| {
                if (keys_result.keys.len > 0) {
                    return try std.mem.join(allocator, "\n", keys_result.keys);
                } else {
                    return try std.fmt.allocPrint(allocator, "(empty)", .{});
                }
            },
            .Ping => |ping_result| {
                return try std.fmt.allocPrint(allocator, "{s}", .{ping_result.response});
            },
            .Benchmark => |benchmark_result| {
                const write_time_ms = @as(f64, @floatFromInt(benchmark_result.write_time_ns)) / 1_000_000.0;
                const read_time_ms = @as(f64, @floatFromInt(benchmark_result.read_time_ns)) / 1_000_000.0;
                const total_time_ms = @as(f64, @floatFromInt(benchmark_result.total_time_ns)) / 1_000_000.0;

                return try std.fmt.allocPrint(allocator, "Benchmark completed: {d} ops, Write: {d:.2}ms, Read: {d:.2}ms, Total: {d:.2}ms", .{ benchmark_result.num_ops, write_time_ms, read_time_ms, total_time_ms });
            },
            .Unknown => |unknown_result| {
                return try std.fmt.allocPrint(allocator, "ERR: {s}", .{unknown_result.errors});
            },
        }
    }
};

// ResultPayload defines the structure of the payload of a command result.
pub const ResultPayload = union(enum) {
    Set: SetResult,
    Keys: KeysResult,
    Get: GetResult,
    Delete: DeleteResult,
    Ping: PingResult,
    Benchmark: BenchmarkResult,
    Unknown: UnknownResult,
};

/// SetRequest defines the request structure for the SET command.
/// `key` is the key to set, and `value` is the value to set it to.
/// `result` is a pointer to the result that will be filled by the server
/// when the command is executed.
pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,

    /// Executes the SET command with the given key and value.
    pub fn execute(self: SetRequest, store: *Phage) !SetResult {
        try store.put(self.key, self.value);
        return SetResult{ .value = self.value };
    }

    /// Converts the SetRequest to a slice of bytes that can be sent over the wire.
    pub fn toSlice(self: SetRequest, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "SET {s} {s}", .{ self.key, self.value });
    }

    /// Parses a slice of bytes into a SetRequest.
    ///
    /// Returns an error if the command is not valid or if the number of arguments is incorrect.
    ///
    /// The slice must start with the command "SET" followed by two arguments: key and value.
    ///
    /// Example:
    /// ```
    /// const request = try SetRequest.fromSlice("SET mykey myvalue");
    /// ```
    ///
    /// If the command is invalid or has the wrong number of arguments, it returns `error.InvalidCommand`.
    ///
    /// If the command is valid, it returns a SetRequest with the key and value set.
    ///
    /// # Errors
    /// - `error.InvalidCommand`: if the command is not "SET" or if the number of arguments is incorrect.
    ///
    /// # Examples
    /// ```
    /// const request = try SetRequest.fromSlice("SET mykey myvalue");
    /// assert(request.key == "mykey");
    /// assert(request.value == "myvalue");
    /// ```
    pub fn fromSlice(slice: []const u8) !SetRequest {
        var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        if (!std.ascii.eqlIgnoreCase(cmd, "SET")) return error.InvalidCommand;

        const key = tokens.next() orelse return error.MissingKey;
        if (key.len == 0) return error.EmptyKey;

        const value = tokens.next() orelse return error.MissingValue;
        if (tokens.next() != null) return error.InvalidCommand;

        return SetRequest{ .key = key, .value = value };
    }
};

/// GetRequest defines the request structure for the GET command.
/// `key` is the key to retrieve, and `result` is a pointer to the result
/// that will be filled by the server when the command is executed.
pub const GetRequest = struct {
    key: []const u8,

    /// Executes the GET command with the given key.
    pub fn execute(self: GetRequest, store: *Phage) ![]const u8 {
        const value = try store.get(self.key);
        return value;
    }

    /// Converts the GetRequest to a slice of bytes that can be sent over the wire.
    pub fn toSlice(self: GetRequest, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "GET {s}", .{self.key});
    }

    /// Parses a slice of bytes into a GetRequest.
    ///
    /// Returns an error if the command is not valid or if the number of arguments is incorrect.
    ///
    /// The slice must start with the command "GET" followed by a single key argument.
    ///
    /// Example:
    /// ```
    /// const request = try GetRequest.fromSlice("GET mykey");
    /// ```
    ///
    /// If the command is invalid or has the wrong number of arguments, it returns `error.InvalidCommand`.
    ///
    /// If the command is valid, it returns a GetRequest with the key set.
    ///
    /// # Errors
    /// - `error.InvalidCommand`: if the command is not "GET" or if the number of arguments is incorrect.
    ///
    /// # Examples
    /// ```
    /// const request = try GetRequest.fromSlice("GET mykey");
    /// assert(request.key == "mykey");
    /// ```
    pub fn fromSlice(slice: []const u8) !GetRequest {
        var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        if (!std.ascii.eqlIgnoreCase(cmd, "GET")) return error.InvalidCommand;

        const key = tokens.next() orelse return error.MissingKey;
        if (key.len == 0) return error.EmptyKey;
        if (tokens.next() != null) return error.InvalidCommand;

        return GetRequest{ .key = key };
    }
};

/// DeleteRequest defines the request structure for the DELETE command.
/// `key` is the key to delete, and `result` is a pointer to the result
/// that will be filled by the server when the command is executed.
pub const DeleteRequest = struct {
    key: []const u8,
    result: ?*DeleteResult = null,

    /// Executes the DELETE command with the given key and stores the result in a DeleteResult.
    pub fn execute(self: DeleteRequest, store: *Phage) !DeleteResult {
        const deleted = try store.delete(self.key);
        return DeleteResult{ .success = deleted };
    }

    /// Converts the DeleteRequest to a slice of bytes that can be sent over the wire.
    pub fn toSlice(self: DeleteRequest, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "DELETE {s}", .{self.key});
    }

    /// Parses a slice of bytes into a DeleteRequest.
    ///
    /// Returns an error if the command is not valid or if the number of arguments is incorrect.
    ///
    /// The slice must start with the command "DELETE" followed by a single key argument.
    ///
    /// Example:
    /// ```
    /// const request = try DeleteRequest.fromSlice("DELETE mykey");
    /// ```
    ///
    /// If the command is invalid or has the wrong number of arguments, it returns `error.InvalidCommand`.
    ///
    /// If the command is valid, it returns a DeleteRequest with the key set.
    ///
    /// # Errors
    /// - `error.InvalidCommand`: if the command is not "DELETE" or if the number of arguments is incorrect.
    ///
    /// # Examples
    /// ```
    /// const request = try DeleteRequest.fromSlice("DELETE mykey");
    /// assert(request.key == "mykey");
    /// ```
    pub fn fromSlice(slice: []const u8) !DeleteRequest {
        var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        if (!std.ascii.eqlIgnoreCase(cmd, "DELETE") and !std.ascii.eqlIgnoreCase(cmd, "DEL")) return error.InvalidCommand;

        const key = tokens.next() orelse return error.MissingKey;
        if (key.len == 0) return error.EmptyKey;
        if (tokens.next() != null) return error.InvalidCommand;

        return DeleteRequest{ .key = key };
    }
};

/// PingRequest defines the request structure for the PING command.
/// `result` is a pointer to the result that will be filled by the server
/// when the command is executed.
pub const PingRequest = struct {
    /// Executes the PING command.
    pub fn execute() ![]const u8 {
        return "PONG\n";
    }

    /// Converts the PingRequest to a slice of bytes that can be sent over the wire.
    pub fn toSlice(allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "PING");
    }

    /// Parses a slice of bytes into a PingRequest.
    ///
    /// Returns an error if the command is not valid or if the number of arguments is incorrect.
    ///
    /// The slice must start with the command "PING".
    ///
    /// Example:
    /// ```
    /// const request = try PingRequest.fromSlice("PING");
    /// ```
    ///
    /// If the command is invalid or has the wrong number of arguments, it returns `error.InvalidCommand`.
    ///
    /// If the command is valid, it returns a PingRequest.
    pub fn fromSlice(slice: []const u8) !PingRequest {
        var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        if (!std.ascii.eqlIgnoreCase(cmd, "PING")) return error.InvalidCommand;
        if (tokens.next() != null) return error.InvalidCommand;
        return PingRequest{};
    }
};

/// KeysRequest defines the request structure for the KEYS command.
///
/// `result` is a pointer to the result that will be filled by the server
/// when the command is executed.
pub const KeysRequest = struct {
    pattern: []const u8,

    /// Executes the KEYS command with the given pattern.
    pub fn execute(self: KeysRequest, store: *Phage) !KeysResult {
        const result = store.findKeys(self.pattern) catch |err| {
            return err;
        };

        return KeysResult{ .keys = result orelse &[_][]const u8{} };
    }

    /// Converts the KeysRequest to a slice of bytes that can be sent over the wire.
    pub fn toSlice(self: KeysRequest, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "KEYS {s}", .{self.pattern});
    }

    /// Parses a slice of bytes into a KeysRequest.
    ///
    /// Returns an error if the command is not valid or if the number of arguments is incorrect.
    ///
    /// The slice must start with the command "KEYS" followed by a single pattern argument.
    ///
    /// Example:
    /// ```
    /// const request = try KeysRequest.fromSlice("KEYS *");
    /// ```
    ///
    /// If the command is invalid or has the wrong number of arguments, it returns `error.InvalidCommand`.
    ///
    /// If the command is valid, it returns a KeysRequest with the pattern set.
    ///
    /// # Errors
    /// - `error.InvalidCommand`: if the command is not "KEYS" or if the number of arguments is incorrect.
    ///
    /// # Examples
    /// ```
    /// const request = try KeysRequest.fromSlice("KEYS *");
    /// assert(request.pattern == "*");
    /// ```
    ///
    /// # Note
    /// The `result` field is not set by this function. It should be set by the server when executing the command.
    pub fn fromSlice(slice: []const u8) !KeysRequest {
        var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        if (!std.ascii.eqlIgnoreCase(cmd, "KEYS")) return error.InvalidCommand;

        const pattern = tokens.next() orelse return error.MissingPattern;
        if (pattern.len == 0) return error.EmptyPattern;
        if (tokens.next() != null) return error.InvalidCommand;

        return KeysRequest{ .pattern = pattern };
    }
};

pub const BenchmarkRequest = struct {
    num_ops: u32,

    /// Converts the BenchmarkRequest to a slice of bytes that can be sent over the wire.
    pub fn toSlice(self: BenchmarkRequest, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "BENCHMARK {d}", .{self.num_ops});
    }

    /// Executes the benchmark request against the given store.
    pub fn execute(self: BenchmarkRequest, store: *Phage) !BenchmarkResult {
        const start_time = std.time.nanoTimestamp();

        // Use batched operations for better performance
        const BATCH_SIZE = 100; // Process in batches to avoid excessive memory usage

        // Perform write operations using batching
        const write_start = std.time.nanoTimestamp();
        var i: u32 = 0;
        while (i < self.num_ops) {
            const batch_end = @min(i + BATCH_SIZE, self.num_ops);
            const batch_size: usize = @intCast(batch_end - i);

            // Prepare batch of key-value pairs
            const pairs = try store.allocator.alloc(Phage.BatchPair, batch_size);
            defer {
                for (pairs) |pair| {
                    store.allocator.free(pair.key);
                    store.allocator.free(pair.value);
                }
                store.allocator.free(pairs);
            }

            for (0..batch_size) |j| {
                const op_index: u32 = i + @as(u32, @intCast(j));
                const key = try std.fmt.allocPrint(store.allocator, "bench_key{d}", .{op_index});
                const value = try std.fmt.allocPrint(store.allocator, "bench_value{d}", .{op_index});
                pairs[j] = .{ .key = key, .value = value };
            }

            // Execute batch PUT
            try store.putBatch(pairs);
            i = batch_end;
        }
        const write_end = std.time.nanoTimestamp();

        // Perform read operations (individual reads are still necessary)
        const read_start = std.time.nanoTimestamp();
        for (0..self.num_ops) |j| {
            const key = try std.fmt.allocPrint(store.allocator, "bench_key{d}", .{j});
            defer store.allocator.free(key);
            const value = try store.get(key);
            defer store.allocator.free(value);
        }
        const read_end = std.time.nanoTimestamp();

        const total_time_ns: u64 = @intCast(read_end - start_time);
        const write_time_ns: u64 = @intCast(write_end - write_start);
        const read_time_ns: u64 = @intCast(read_end - read_start);

        return BenchmarkResult{
            .num_ops = self.num_ops,
            .total_time_ns = total_time_ns,
            .write_time_ns = write_time_ns,
            .read_time_ns = read_time_ns,
        };
    }

    /// Parses a slice of bytes into a BenchmarkRequest.
    pub fn fromSlice(slice: []const u8) !BenchmarkRequest {
        var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        if (!std.ascii.eqlIgnoreCase(cmd, "BENCHMARK")) return error.InvalidCommand;

        const num_ops_str = tokens.next() orelse return error.MissingBenchmarkOperations;
        if (tokens.next() != null) return error.InvalidCommand;

        const num_ops = std.fmt.parseInt(u32, num_ops_str, 10) catch return error.InvalidCommand;
        if (num_ops == 0 or num_ops > 1_000_000) return error.InvalidCommand;
        return BenchmarkRequest{ .num_ops = num_ops };
    }
};

pub const SetResult = struct {
    value: []const u8,
};

pub const GetResult = struct {
    value: []const u8,
};

pub const DeleteResult = struct {
    success: bool,
};

pub const PingResult = struct {
    response: []const u8, // Typically "PONG\n" :-)
};

pub const KeysResult = struct {
    keys: [][]const u8,
};

pub const BenchmarkResult = struct {
    num_ops: u32,
    total_time_ns: u64,
    write_time_ns: u64,
    read_time_ns: u64,
};

pub const UnknownResult = struct {
    errors: []const u8,
};

fn parseCommandType(cmd: []const u8) ?CommandType {
    if (std.ascii.eqlIgnoreCase(cmd, "SET")) return .Set;
    if (std.ascii.eqlIgnoreCase(cmd, "GET")) return .Get;
    if (std.ascii.eqlIgnoreCase(cmd, "DELETE") or std.ascii.eqlIgnoreCase(cmd, "DEL")) return .Delete;
    if (std.ascii.eqlIgnoreCase(cmd, "KEYS")) return .Keys;
    if (std.ascii.eqlIgnoreCase(cmd, "PING")) return .Ping;
    if (std.ascii.eqlIgnoreCase(cmd, "BENCHMARK")) return .Benchmark;
    return null;
}

/// Returns the next unique command ID.
pub fn nextCommandId() u32 {
    // Atomically increment the command ID and return the new value.
    return next_command_id.fetchAdd(1, .seq_cst);
}

// Parses a command from a slice of bytes and returns a Command.
pub fn parseCommandSlice(slice: []const u8) !Command {
    var tokens = std.mem.tokenizeAny(u8, slice, " \t\r\n");
    const cmd = tokens.next() orelse return error.InvalidCommand;

    const command_type = parseCommandType(cmd) orelse return error.InvalidCommand;

    switch (command_type) {
        .Set => {
            const request = try SetRequest.fromSlice(slice);
            return Command{
                .id = nextCommandId(),
                .command = .Set,
                .payload = .{ .Set = request },
                .result = null,
            };
        },
        .Get => {
            const request = try GetRequest.fromSlice(slice);
            return Command{
                .id = nextCommandId(),
                .command = .Get,
                .payload = .{ .Get = request },
                .result = null,
            };
        },
        .Delete => {
            const request = try DeleteRequest.fromSlice(slice);
            return Command{
                .id = nextCommandId(),
                .command = .Delete,
                .payload = .{ .Delete = request },
                .result = null,
            };
        },
        .Keys => {
            const request = try KeysRequest.fromSlice(slice);
            return Command{
                .id = nextCommandId(),
                .command = .Keys,
                .payload = .{ .Keys = request },
                .result = null,
            };
        },
        .Ping => {
            const request = try PingRequest.fromSlice(slice);
            return Command{
                .id = nextCommandId(),
                .command = .Ping,
                .payload = .{ .Ping = request },
                .result = null,
            };
        },
        .Benchmark => {
            const request = try BenchmarkRequest.fromSlice(slice);
            return Command{
                .id = nextCommandId(),
                .command = .Benchmark,
                .payload = .{ .Benchmark = request },
                .result = null,
            };
        },
        else => {
            return Command.unknown();
        },
    }
}

test "parse_command_slice" {
    const command_string = "KEYS *";
    const command = try parseCommandSlice(command_string);

    const expected = Command.keys("*");
    try std.testing.expectEqualStrings(command.payload.Keys.pattern, expected.payload.Keys.pattern);
    try std.testing.expectEqual(command.command, expected.command);
}

test "test_keys_request" {
    const allocator = std.heap.page_allocator;
    const command_string = "KEYS *";
    const request = try KeysRequest.fromSlice(command_string);

    const expected = KeysRequest{ .pattern = "*" };
    try std.testing.expectEqualStrings(request.pattern, expected.pattern);

    const result = try request.toSlice(allocator);
    try std.testing.expectEqualStrings(result, "KEYS *");
}

test "protocol:keys_with_no_args" {
    const command_string = "KEYS";

    try std.testing.expectError(
        error.MissingPattern,
        KeysRequest.fromSlice(command_string),
    );
}

test "protocol:keys_with_too_many_args" {
    const command_string = "KEYS * *";

    try std.testing.expectError(
        error.InvalidCommand,
        KeysRequest.fromSlice(command_string),
    );
}

test "protocol parser rejects missing arguments with specific errors" {
    try std.testing.expectError(error.MissingKey, parseCommandSlice("SET"));
    try std.testing.expectError(error.MissingValue, parseCommandSlice("SET key"));
    try std.testing.expectError(error.MissingKey, parseCommandSlice("GET"));
    try std.testing.expectError(error.MissingKey, parseCommandSlice("DELETE"));
    try std.testing.expectError(error.MissingPattern, parseCommandSlice("KEYS"));
    try std.testing.expectError(error.MissingBenchmarkOperations, parseCommandSlice("BENCHMARK"));
}

test "protocol parser rejects malformed extra arguments" {
    try std.testing.expectError(error.InvalidCommand, parseCommandSlice("GET key extra"));
    try std.testing.expectError(error.InvalidCommand, parseCommandSlice("DELETE key extra"));
    try std.testing.expectError(error.InvalidCommand, parseCommandSlice("PING extra"));
    try std.testing.expectError(error.InvalidCommand, parseCommandSlice("BENCHMARK 10 extra"));
}

test "protocol parser handles case, aliases, and whitespace without panics" {
    const set = try parseCommandSlice("  set\talpha beta\r\n");
    try std.testing.expectEqual(CommandType.Set, set.command);
    try std.testing.expectEqualStrings("alpha", set.payload.Set.key);
    try std.testing.expectEqualStrings("beta", set.payload.Set.value);

    const del = try parseCommandSlice("del alpha");
    try std.testing.expectEqual(CommandType.Delete, del.command);
    try std.testing.expectEqualStrings("alpha", del.payload.Delete.key);

    try std.testing.expectError(error.InvalidCommand, parseCommandSlice("THIS_COMMAND_NAME_IS_LONGER_THAN_16_BYTES key"));
}

test "benchmark request validates operation bounds" {
    try std.testing.expectError(error.InvalidCommand, BenchmarkRequest.fromSlice("BENCHMARK 0"));
    try std.testing.expectError(error.InvalidCommand, BenchmarkRequest.fromSlice("BENCHMARK 1000001"));

    const request = try BenchmarkRequest.fromSlice("BENCHMARK 1000000");
    try std.testing.expectEqual(@as(u32, 1_000_000), request.num_ops);
}
