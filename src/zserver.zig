const std = @import("std");
const mem = @import("std").mem;

const phage = @import("phage");
const zimq = @import("zimq");

const Config = struct {
    port: u16 = 5555,
    db_path: []const u8 = "phage_store",
    log_level: std.log.Level = .info,
    help: bool = false,
};

fn printUsage(program_name: []const u8) void {
    std.debug.print("Usage: {s} [OPTIONS]\n", .{program_name});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -p, --port PORT       Set server port (default: 5555)\n", .{});
    std.debug.print("  -d, --db-path PATH    Set database file path (default: phage_store)\n", .{});
    std.debug.print("  -l, --log-level LEVEL Set log level: debug, info, warn, err (default: info)\n", .{});
    std.debug.print("  -h, --help            Show this help message\n", .{});
    std.debug.print("\nExamples:\n", .{});
    std.debug.print("  {s}                           # Start with defaults\n", .{program_name});
    std.debug.print("  {s} --port 8080               # Start on port 8080\n", .{program_name});
    std.debug.print("  {s} --db-path /tmp/mydb       # Use custom database path\n", .{program_name});
    std.debug.print("  {s} --log-level debug         # Enable debug logging\n", .{program_name});
}

fn parseLogLevel(level_str: []const u8) !std.log.Level {
    if (std.mem.eql(u8, level_str, "debug")) return .debug;
    if (std.mem.eql(u8, level_str, "info")) return .info;
    if (std.mem.eql(u8, level_str, "warn")) return .warn;
    if (std.mem.eql(u8, level_str, "err")) return .err;
    return error.InvalidLogLevel;
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    var config = Config{};
    
    var i: usize = 1; // Skip program name
    while (i < args.len) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            config.help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --port requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.port = std.fmt.parseInt(u16, args[i], 10) catch |err| {
                std.debug.print("Error: Invalid port number '{s}': {}\n", .{ args[i], err });
                return error.InvalidPort;
            };
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--db-path")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --db-path requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.db_path = args[i];
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --log-level requires a value\n", .{});
                return error.InvalidArgs;
            }
            config.log_level = parseLogLevel(args[i]) catch |err| {
                std.debug.print("Error: Invalid log level '{s}': {}\n", .{ args[i], err });
                return error.InvalidLogLevel;
            };
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
            return error.UnknownArg;
        }
        i += 1;
    }
    
    return config;
}

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

    // Parse command line arguments
    const config = parseArgs(allocator_ptr) catch |err| switch (err) {
        error.InvalidArgs, error.InvalidPort, error.InvalidLogLevel, error.UnknownArg => {
            printUsage("phage");
            return;
        },
        else => return err,
    };

    if (config.help) {
        printUsage("phage");
        return;
    }

    // Set log level (this is a compile-time feature in Zig, but we can at least show what was requested)
    std.debug.print("Starting Phage server with configuration:\n", .{});
    std.debug.print("  Port: {}\n", .{config.port});
    std.debug.print("  Database: {s}\n", .{config.db_path});
    std.debug.print("  Log Level: {}\n", .{config.log_level});

    var store: phage.Phage = try .init(allocator_ptr, config.db_path);
    defer store.deinit();

    const ctx: *zimq.Context = try .init();
    defer ctx.deinit();

    const server_rep: *zimq.Socket = try .init(ctx, .rep);
    defer server_rep.deinit();

    // Use configured port
    const bind_address = try std.fmt.allocPrintZ(allocator_ptr, "tcp://*:{}", .{config.port});
    defer allocator_ptr.free(bind_address);
    
    try server_rep.bind(bind_address);

    while (true) {
        var buf: zimq.Message = .empty();
        _ = try server_rep.recvMsg(&buf, .{});

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
                else => "ERR Invalid command\n",
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
}
