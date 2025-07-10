const std = @import("std");
pub const protocol = @This();

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
/// `[command] [args...] \n`
///
/// - [command] must always be the first word in the line.
/// - [args...] are optional arguments that follow the command.
///
/// ### PING / PONG
///
/// Client: PING?\n (6 bytes)
/// Server: PONG!\n (6 bytes)
///
/// ### GET / PUT / DELETE
///
/// Client: GET key\n (8 bytes)
/// Server: value\n (6 bytes)
/// Client: PUT key value\n (12 bytes)
/// Server: OK\n (3 bytes)
/// Client: DELETE key\n (12 bytes)
/// Server: OK\n (3 bytes)
///

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
    pub fn init(id: u32, command: CommandType) Command {
        return Command{
            .id = id,
            .command = command,
            .payload = Payload.Unknown,
            .result = null,
        };
    }

    /// Returns the command name as a slice.
    pub fn name(self: Command) []const u8 {
        switch (self.command) {
            .Set => return "SET",
            .Get => return "GET",
            .Delete => return "DELETE",
            .Keys => return "KEYS",
            .Ping => return "PING",
            .Unknown => return "UNKNOWN",
        }
    }

    /// Creates a new Keys command with the given ID and pattern,
    /// initializing the payload to a KeysRequest with the given pattern.
    pub fn keys(pattern: []const u8) Command {
        const id: u32 = 0; // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
        return Command{
            .id = id,
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
    pub fn unknown(id: u32) Command {
        return Command{
            .id = id,
            .command = CommandType.Unknown,
            .payload = .{
                .Unknown = {},
            },
            .result = null,
        };
    }
};

// Payload defines the structure of the payload of a command.
pub const Payload = union(enum) {
    Set: SetRequest,
    Get: GetRequest,
    Delete: DeleteRequest,
    Keys: KeysRequest,
    Ping: PingRequest,
    Unknown,
};

// Result defines the structure of a command result sent from the server.
pub const Result = struct {
    id: u32,
    status: Status,
    payload: ResultPayload,
};

// ResultPayload defines the structure of the payload of a command result.
pub const ResultPayload = union(enum) {
    Set: SetResult,
    Keys: KeysResult,
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
        var tokens = std.mem.splitSequence(u8, slice, " ");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        const key = tokens.next() orelse return error.InvalidCommand;
        const value = tokens.next() orelse return error.InvalidCommand;

        if (std.mem.eql(u8, cmd, "SET")) {
            return SetRequest{ .key = key, .value = value };
        } else {
            return error.InvalidCommand;
        }
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
        var tokens = std.mem.splitSequence(u8, slice, " ");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        const key = tokens.next() orelse return error.InvalidCommand;

        if (std.mem.eql(u8, cmd, "GET")) {
            return GetRequest{ .key = key };
        } else {
            return error.InvalidCommand;
        }
    }
};

/// DeleteRequest defines the request structure for the DELETE command.
/// `key` is the key to delete, and `result` is a pointer to the result
/// that will be filled by the server when the command is executed.
pub const DeleteRequest = struct {
    key: []const u8,

    /// Executes the DELETE command with the given key.
    pub fn execute(self: DeleteRequest, store: *Phage) !bool {
        const deleted = try store.delete(self.key);
        return deleted;
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
        var tokens = std.mem.splitSequence(u8, slice, " ");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        const key = tokens.next() orelse return error.InvalidCommand;

        if (std.mem.eql(u8, cmd, "DELETE")) {
            return DeleteRequest{ .key = key };
        } else {
            return error.InvalidCommand;
        }
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
        if (std.mem.eql(u8, slice, "PING")) {
            return PingRequest{};
        } else {
            return error.InvalidCommand;
        }
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

        return KeysResult{ .keys = result };
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
        var tokens = std.mem.splitSequence(u8, slice, " ");
        const cmd = tokens.next() orelse return error.InvalidCommand;
        const pattern = tokens.rest();

        if (pattern.len != 1) {
            return error.InvalidCommand;
        }

        if (std.mem.eql(u8, cmd, "KEYS")) {
            return KeysRequest{ .pattern = pattern };
        } else {
            return error.InvalidCommand;
        }
    }
};

pub const SetResult = struct {
    value: []const u8,
};

pub const KeysResult = struct {
    keys: [][]const u8,
};

pub const UnknownResult = struct {
    errors: []const u8,
};

// CommandMap is a ComptimeStringMap that maps command names to their corresponding CommandType
// with O(1) lookup time.
const CommandMap = std.StaticStringMap(CommandType).initComptime(.{
    .{ "SET", CommandType.Set },
    .{ "GET", CommandType.Get },
    .{ "DELETE", CommandType.Delete },
    .{ "KEYS", CommandType.Keys },
    .{ "PING", CommandType.Ping },
    .{ "UNKNOWN", CommandType.Unknown },
});

// Parses a command from a slice of bytes and returns a Command.
pub fn parseCommandSlice(slice: []const u8) !Command {
    var tokens = std.mem.splitSequence(u8, slice, " ");
    const cmd = tokens.next() orelse return error.InvalidCommand;

    var cmd_upper_buffer: [16]u8 = undefined;
    const cmd_upper = std.ascii.upperString(cmd_upper_buffer[0..cmd.len], cmd);

    const command_type = CommandMap.get(cmd_upper) orelse return error.InvalidCommand;

    switch (command_type) {
        .Set => {
            const request = try SetRequest.fromSlice(slice);
            return Command{
                .id = 0, // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
                .command = .Set,
                .payload = .{ .Set = request },
                .result = null,
            };
        },
        .Get => {
            const request = try GetRequest.fromSlice(slice);
            return Command{
                .id = 0, // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
                .command = .Get,
                .payload = .{ .Get = request },
                .result = null,
            };
        },
        .Delete => {
            const request = try DeleteRequest.fromSlice(slice);
            return Command{
                .id = 0, // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
                .command = .Delete,
                .payload = .{ .Delete = request },
                .result = null,
            };
        },
        .Keys => {
            const request = try KeysRequest.fromSlice(slice);
            return Command{
                .id = 0, // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
                .command = .Keys,
                .payload = .{ .Keys = request },
                .result = null,
            };
        },
        .Ping => {
            const request = try PingRequest.fromSlice(slice);
            return Command{
                .id = 0, // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
                .command = .Ping,
                .payload = .{ .Ping = request },
                .result = null,
            };
        },
        else => {
            return Command.unknown(0); // TODO: Generate a unique ID for the command that we can track across ZMQ messages.
        },
    }
}

/// Executes a command on the Phage store and returns the result as a slice of bytes.
pub fn executeCommand(store: *Phage, command: protocol.Command) ![]const u8 {
    std.log.debug("Executing command: {s}", .{command.name()});

    switch (command.command) {
        .Set => {
            try store.put(command.payload.Set.key, command.payload.Set.value);
            return "OK\n";
        },
        .Get => {
            const value = try store.get(command.payload.Get.key);
            return value;
        },
        .Delete => {
            const deleted = try store.delete(command.payload.Delete.key);
            if (deleted) {
                return "OK\n";
            } else {
                return "NOT_FOUND\n";
            }
        },
        .Keys => |_| {
            const keys = try store.findKeys(command.payload.Keys.pattern);
            if (keys) |k| {
                return try std.fmt.allocPrint(store.allocator, "{s}\n", .{try std.mem.join(store.allocator, "\n", k)});
            } else {
                return "0\n";
            }
        },
        else => {
            std.log.err("Unknown command: {s}", .{command.name()});
            return error.UnknownCommand;
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
        error.InvalidCommand,
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
