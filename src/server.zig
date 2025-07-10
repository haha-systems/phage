const std = @import("std");
const Phage = @import("root.zig").Phage;
const commands = @import("protocol/commands.zig");

const log = @import("colored_logger").myLogFn;

const DEFAULT_PORT: u16 = 6379;
const BUFFER_SIZE: usize = 1024 * 4;
const MAX_IN_FLIGHT: usize = 128;

const ClientMode = enum {
    reading_command,
    writing_response,
};

const Client = struct {
    buffer: [BUFFER_SIZE]u8,
    buf_pos: usize = 0,
    file: std.fs.File,
    writer: *std.io.AnyWriter,
    mode: ClientMode,
};

const ACCEPT_USER_DATA = 0xdeadbeef;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var store = try Phage.init(allocator, "phage.db");
    defer store.deinit();

    const env_map = try allocator.create(std.process.EnvMap);
    env_map.* = try std.process.getEnvMap(store.allocator);
    defer env_map.deinit();

    const parsed_port = std.process.getEnvVarOwned(store.allocator, "PHAGE_PORT") catch |err| {
        log(.warn, .phage_server, "Environment variable PHAGE_PORT not set, using default port {d}", .{DEFAULT_PORT});
        return err;
    };

    const port = std.fmt.parseInt(u16, parsed_port, 10) catch |err| {
        log(.err, .phage_server, "Invalid port number: {s}", .{parsed_port});
        return err;
    };

    log(.info, .phage_server, "Starting server on port {d}", .{port});
    try startServer(&store, port);
}

pub fn startServer(store: *Phage, port: u16) !void {
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port);
    const server_fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM,
        std.posix.IPPROTO.TCP,
    );

    try std.posix.bind(server_fd, &address.any, address.getOsSockLen());
    try std.posix.listen(server_fd, MAX_IN_FLIGHT);
    store.server_fd = server_fd;

    var ring = try std.os.linux.IoUring.init(MAX_IN_FLIGHT, 0);
    defer ring.deinit();

    var clients = std.AutoHashMap(i32, Client).init(store.allocator);
    defer clients.deinit();

    try prepareAccept(&ring, server_fd);

    log(.info, .phage_server, "Server started on port {d}", .{port});

    while (true) {
        _ = try ring.submit();
        const cqe = try ring.copy_cqe();

        if (cqe.user_data == ACCEPT_USER_DATA) {
            log(.info, .phage_server, "Accepting new connection", .{});
            try handleAcceptCompletion(&ring, &clients, cqe, store);
        } else {
            log(.info, .phage_server, "Handling client completion", .{});
            try handleClientCompletion(&ring, &clients, cqe, store);
        }
    }
}

fn prepareAccept(ring: *std.os.linux.IoUring, server_fd: std.posix.fd_t) !void {
    var accept_sqe = try ring.get_sqe();
    accept_sqe.prep_accept(server_fd, null, null, 0);
    accept_sqe.user_data = ACCEPT_USER_DATA;
}

fn handleAcceptCompletion(
    ring: *std.os.linux.IoUring,
    clients: *std.AutoHashMap(i32, Client),
    cqe: std.os.linux.io_uring_cqe,
    store: *Phage,
) !void {
    log(.info, .phage_server, "Accepted new connection", .{});

    if (cqe.res < 0) {
        const res: isize = @intCast(cqe.res);
        log(.err, .phage_server, "Accept failed with error: {d}", .{std.posix.errno(res)});
        return;
    }

    const client_fd = cqe.res;
    const client = try store.allocator.create(Client);

    client.file = std.fs.File{ .handle = client_fd };
    client.buffer = [_]u8{0} ** BUFFER_SIZE;
    client.mode = ClientMode.reading_command;

    const writer = try store.allocator.create(std.io.AnyWriter);
    writer.* = client.file.writer().any();
    client.writer = writer;

    try clients.put(client_fd, client.*);

    var read_sqe = try ring.get_sqe();
    read_sqe.prep_recv(client_fd, &client.buffer, 0);
    read_sqe.user_data = @intFromPtr(client);

    try prepareAccept(ring, store.server_fd);
}

fn handleClientCompletion(
    ring: *std.os.linux.IoUring,
    clients: *std.AutoHashMap(i32, Client),
    cqe: std.os.linux.io_uring_cqe,
    store: *Phage,
) !void {
    const client_ptr: *Client = @ptrFromInt(cqe.user_data);

    if (cqe.res == 0) {
        log(.info, .phage_server, "End of read", .{});
        _ = clients.remove(client_ptr.file.handle);
        return;
    }

    if (cqe.res == @intFromEnum(std.posix.E.PIPE)) {
        log(.err, .phage_server, "Error: broken pipe", .{});
        _ = clients.remove(client_ptr.file.handle);
        return;
    } else if (cqe.res < 0) {
        const res: isize = @intCast(cqe.res);
        log(.err, .phage_server, "Read failed with error: {d}", .{std.posix.errno(res)});
        _ = clients.remove(client_ptr.file.handle);
        return;
    }

    log(.info, .phage_server, "Read completed with {d} bytes", .{cqe.res});
    log(.info, .phage_server, "Client mode: {}", .{client_ptr.mode});

    switch (client_ptr.mode) {
        .reading_command => {
            log(.info, .phage_server, "Reading command", .{});
            log(.info, .phage_server, "Bytes read: {d}", .{cqe.res});
            log(.info, .phage_server, "Buffer: {s}", .{client_ptr.buffer});
            try handleReadCommand(client_ptr, ring, store, cqe.res);
        },
        .writing_response => {
            log(.info, .phage_server, "Writing response", .{});
            try handleWriteResponse(client_ptr, ring);
        },
    }
}

fn handleReadCommand(client_ptr: *Client, ring: *std.os.linux.IoUring, store: *Phage, bytes_read: i32) !void {
    log(.info, .phage_server, "Handling read command", .{});

    if (bytes_read == 0) {
        log(.info, .phage_server, "End of read", .{});
        return;
    }

    // All commands are terminated by a newline: 'PING\n'
    // TODO: could be made much easier by checking the last byte is a newline?
    if (std.mem.indexOfScalar(u8, client_ptr.buffer[0..@intCast(bytes_read)], '\n')) |nl_pos| {
        const line = client_ptr.buffer[0..nl_pos];

        // Is this a valid command?
        log(.info, .phage_server, "Processing command: {s}", .{line});
        if (commands.validateCommand(line)) {
            log(.info, .phage_server, "Valid command", .{});
            // clear the writer from any previous writes
            
            // Attempt to execute the command we were sent
            commands.executeCommand(store, store.allocator, line) catch |err| {
                log(.err, .phage_server, "Error executing command: {}", .{err});
                return err;
            };

            try writeResponse(client_ptr, ring, "OK\n", .{});
        } else {
            log(.err, .phage_server, "Invalid command: {s}", .{line});
            try writeResponse(client_ptr, ring, "Error: Invalid command: {s}\n", .{line});
        }
    } else {
        log(.err, .phage_server, "Invalid command: {s}", .{client_ptr.buffer[0..@intCast(bytes_read)]});
        var read_sqe = try ring.get_sqe();
        read_sqe.prep_read(client_ptr.file.handle, client_ptr.buffer[@intCast(bytes_read)..], 0);
        read_sqe.user_data = @intFromPtr(client_ptr);
    }
}

fn handleWriteResponse(client_ptr: *Client, ring: *std.os.linux.IoUring) !void {
    client_ptr.mode = .reading_command;

    var read_sqe = try ring.get_sqe();
    read_sqe.prep_read(client_ptr.file.handle, client_ptr.buffer[0..], 0);
    read_sqe.user_data = @intFromPtr(client_ptr);
}

fn writeResponse(client: *Client, ring: *std.os.linux.IoUring, comptime fmt: []const u8, args: anytype) !void {
    var buf: [BUFFER_SIZE]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, fmt, args);

    var write_sqe = try ring.get_sqe();
    write_sqe.prep_write(client.file.handle, response, 0);
    write_sqe.user_data = @intFromPtr(client);

    client.mode = .writing_response;
}
