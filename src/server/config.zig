const std = @import("std");

pub const RuntimeMode = enum {
    serialized,
    concurrent,
};

pub const max_worker_count: usize = 16;

pub const Config = struct {
    port: u16 = 5555,
    db_path: []const u8 = "phage_store",
    log_level: std.log.Level = .info,
    runtime: RuntimeMode = .serialized,
    workers: usize = 1,
    help: bool = false,
};

pub const ParseError = error{
    MissingValue,
    InvalidPort,
    InvalidLogLevel,
    InvalidRuntime,
    InvalidWorkers,
    UnknownArgument,
};

/// Parses a process-style argument slice whose first element is argv[0].
pub fn parseArgSlice(args: []const []const u8) ParseError!Config {
    var config = Config{};

    var i: usize = 1; // Skip program name when present.
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            config.help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            const value = nextValue(args, &i) orelse return error.MissingValue;
            config.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--db-path")) {
            config.db_path = nextValue(args, &i) orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--log-level")) {
            const value = nextValue(args, &i) orelse return error.MissingValue;
            config.log_level = parseLogLevel(value) catch return error.InvalidLogLevel;
        } else if (std.mem.eql(u8, arg, "--runtime")) {
            const value = nextValue(args, &i) orelse return error.MissingValue;
            config.runtime = parseRuntimeMode(value) catch return error.InvalidRuntime;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const value = nextValue(args, &i) orelse return error.MissingValue;
            config.workers = parseWorkerCount(value) catch return error.InvalidWorkers;
        } else {
            return error.UnknownArgument;
        }

        i += 1;
    }

    return config;
}

fn nextValue(args: []const []const u8, index: *usize) ?[]const u8 {
    index.* += 1;
    if (index.* >= args.len) return null;
    return args[index.*];
}

pub fn parseLogLevel(level_str: []const u8) ParseError!std.log.Level {
    if (std.mem.eql(u8, level_str, "debug")) return .debug;
    if (std.mem.eql(u8, level_str, "info")) return .info;
    if (std.mem.eql(u8, level_str, "warn")) return .warn;
    if (std.mem.eql(u8, level_str, "err")) return .err;
    return error.InvalidLogLevel;
}

pub fn parseRuntimeMode(value: []const u8) ParseError!RuntimeMode {
    if (std.mem.eql(u8, value, "serialized")) return .serialized;
    if (std.mem.eql(u8, value, "concurrent")) return .concurrent;
    return error.InvalidRuntime;
}

pub fn parseWorkerCount(value: []const u8) ParseError!usize {
    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidWorkers;
    if (parsed == 0 or parsed > max_worker_count) return error.InvalidWorkers;
    return parsed;
}

pub fn runtimeModelName(mode: RuntimeMode) []const u8 {
    return switch (mode) {
        .serialized => "multi-client-serialized-req-rep",
        .concurrent => "bounded-router-serialized-store",
    };
}

pub fn writeUsage(writer: *std.io.AnyWriter, program_name: []const u8) !void {
    try writer.print("Usage: {s} [OPTIONS]\n", .{program_name});
    try writer.writeAll("\nOptions:\n");
    try writer.writeAll("  -p, --port PORT       Set server port (default: 5555)\n");
    try writer.writeAll("  -d, --db-path PATH    Set database file path (default: phage_store)\n");
    try writer.writeAll("  -l, --log-level LEVEL Set log level: debug, info, warn, err (default: info)\n");
    try writer.writeAll("      --runtime MODE    Set runtime mode: serialized, concurrent (default: serialized)\n");
    try writer.writeAll("      --workers N       Set bounded concurrent workers, 1-16 (default: 1)\n");
    try writer.writeAll("  -h, --help            Show this help message\n");
    try writer.writeAll("\nExamples:\n");
    try writer.print("  {s}                           # Start with defaults\n", .{program_name});
    try writer.print("  {s} --port 8080               # Start on port 8080\n", .{program_name});
    try writer.print("  {s} --db-path /tmp/mydb       # Use custom database path\n", .{program_name});
    try writer.print("  {s} --log-level debug         # Enable debug logging\n", .{program_name});
    try writer.print("  {s} --runtime concurrent --workers 2 # Opt into bounded concurrent network scheduling\n", .{program_name});
}

pub fn writeParseError(writer: *std.io.AnyWriter, err: ParseError) !void {
    switch (err) {
        error.MissingValue => try writer.writeAll("Error: option requires a value\n"),
        error.InvalidPort => try writer.writeAll("Error: invalid port; expected a number from 0 to 65535\n"),
        error.InvalidLogLevel => try writer.writeAll("Error: invalid log level; expected debug, info, warn, or err\n"),
        error.InvalidRuntime => try writer.writeAll("Error: invalid runtime; expected serialized or concurrent\n"),
        error.InvalidWorkers => try writer.writeAll("Error: invalid workers; expected a number from 1 through 16\n"),
        error.UnknownArgument => try writer.writeAll("Error: unknown argument\n"),
    }
}

test "server config parser preserves documented defaults" {
    const parsed = try parseArgSlice(&.{"phage"});

    try std.testing.expectEqual(@as(u16, 5555), parsed.port);
    try std.testing.expectEqualStrings("phage_store", parsed.db_path);
    try std.testing.expectEqual(std.log.Level.info, parsed.log_level);
    try std.testing.expect(!parsed.help);
}

test "server config parser recognizes help without requiring runtime resources" {
    const parsed = try parseArgSlice(&.{ "phage", "--help" });

    try std.testing.expect(parsed.help);
    try std.testing.expectEqual(@as(u16, 5555), parsed.port);
    try std.testing.expectEqualStrings("phage_store", parsed.db_path);
}

test "server config parser accepts port db path and log level options" {
    const parsed = try parseArgSlice(&.{ "phage", "--port", "7777", "--db-path", "/tmp/phage-cli-test", "--log-level", "debug" });

    try std.testing.expectEqual(@as(u16, 7777), parsed.port);
    try std.testing.expectEqualStrings("/tmp/phage-cli-test", parsed.db_path);
    try std.testing.expectEqual(std.log.Level.debug, parsed.log_level);
}

test "server config parser accepts short options" {
    const parsed = try parseArgSlice(&.{ "phage", "-p", "6000", "-d", "/tmp/phage-short", "-l", "warn" });

    try std.testing.expectEqual(@as(u16, 6000), parsed.port);
    try std.testing.expectEqualStrings("/tmp/phage-short", parsed.db_path);
    try std.testing.expectEqual(std.log.Level.warn, parsed.log_level);
}

test "server config parser rejects invalid ports" {
    try std.testing.expectError(error.InvalidPort, parseArgSlice(&.{ "phage", "--port", "not-a-port" }));
    try std.testing.expectError(error.InvalidPort, parseArgSlice(&.{ "phage", "--port", "70000" }));
}

test "server config parser rejects unknown arguments" {
    try std.testing.expectError(error.UnknownArgument, parseArgSlice(&.{ "phage", "--wat" }));
}

test "server config parser rejects missing argument values" {
    try std.testing.expectError(error.MissingValue, parseArgSlice(&.{ "phage", "--port" }));
    try std.testing.expectError(error.MissingValue, parseArgSlice(&.{ "phage", "--db-path" }));
    try std.testing.expectError(error.MissingValue, parseArgSlice(&.{ "phage", "--log-level" }));
}

test "server config parser rejects invalid log level" {
    try std.testing.expectError(error.InvalidLogLevel, parseArgSlice(&.{ "phage", "--log-level", "trace" }));
}

test "server config parser defaults to serialized runtime and one worker" {
    const parsed = try parseArgSlice(&.{"phage"});

    try std.testing.expectEqual(RuntimeMode.serialized, parsed.runtime);
    try std.testing.expectEqual(@as(usize, 1), parsed.workers);
}

test "server config parser accepts opt in concurrent runtime and workers" {
    const parsed = try parseArgSlice(&.{ "phage", "--runtime", "concurrent", "--workers", "2" });

    try std.testing.expectEqual(RuntimeMode.concurrent, parsed.runtime);
    try std.testing.expectEqual(@as(usize, 2), parsed.workers);
}

test "server config parser accepts explicit serialized runtime" {
    const parsed = try parseArgSlice(&.{ "phage", "--runtime", "serialized", "--workers", "1" });

    try std.testing.expectEqual(RuntimeMode.serialized, parsed.runtime);
    try std.testing.expectEqual(@as(usize, 1), parsed.workers);
}

test "server config parser rejects unsafe worker counts" {
    try std.testing.expectError(error.InvalidWorkers, parseArgSlice(&.{ "phage", "--workers", "0" }));
    try std.testing.expectError(error.InvalidWorkers, parseArgSlice(&.{ "phage", "--workers", "-1" }));
    try std.testing.expectError(error.InvalidWorkers, parseArgSlice(&.{ "phage", "--workers", "17" }));
}

test "server config parser rejects invalid runtime mode" {
    try std.testing.expectError(error.InvalidRuntime, parseArgSlice(&.{ "phage", "--runtime", "parallel" }));
}

test "server usage text documents supported options and defaults" {
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var writer = output.writer().any();

    try writeUsage(&writer, "phage-server");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Usage: phage-server [OPTIONS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "--port PORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default: 5555") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "--db-path PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default: phage_store") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "--log-level LEVEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default: info") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "--runtime MODE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "serialized, concurrent") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default: serialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "--workers N") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "1-16") != null);
}
