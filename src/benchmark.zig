const std = @import("std");
const phage = @import("phage");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const Config = struct {
    ops: u32 = 10_000,
    db_path: []const u8 = "phage_benchmark_store",
    owned_db_path: ?[]u8 = null,
    fresh: bool = true,
};

fn usage(program_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPS] [--db-path PATH] [--reuse]
        \\
        \\Runs the built-in BENCHMARK command locally without requiring the ZMQ server.
        \\
        \\Options:
        \\  OPS              Number of write/read operations (default: 10000)
        \\  --db-path PATH   Database path to benchmark (default: phage_benchmark_store)
        \\  --reuse          Reuse an existing database instead of deleting it first
        \\  -h, --help       Show this help
        \\
    , .{program_name});
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    var saw_ops = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(args[0]);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--db-path")) {
            i += 1;
            if (i >= args.len) return error.MissingDbPath;
            const owned_path = try allocator.dupe(u8, args[i]);
            if (config.owned_db_path) |old_path| allocator.free(old_path);
            config.db_path = owned_path;
            config.owned_db_path = owned_path;
        } else if (std.mem.eql(u8, arg, "--reuse")) {
            config.fresh = false;
        } else if (!saw_ops) {
            config.ops = try std.fmt.parseInt(u32, arg, 10);
            saw_ops = true;
        } else {
            return error.UnknownArgument;
        }
    }

    return config;
}

fn removeIfExists(path: []const u8) void {
    std.posix.unlink(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("failed to remove {s}: {s}", .{ path, @errorName(err) }),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        usage("phage-benchmark");
        return err;
    };
    defer if (config.owned_db_path) |db_path| allocator.free(db_path);

    if (config.fresh) {
        removeIfExists(config.db_path);
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{config.db_path});
        defer allocator.free(wal_path);
        removeIfExists(wal_path);
    }

    var store = try phage.Phage.init(allocator, config.db_path);
    defer store.deinit();

    const command = try std.fmt.allocPrint(allocator, "BENCHMARK {d}", .{config.ops});
    defer allocator.free(command);
    try phage.protocol.commands.executeCommand(&store, allocator, command);
}
