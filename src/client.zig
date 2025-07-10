const std = @import("std");

pub fn main() !void {
    // open a socket to the server
    // const allocator = std.heap.page_allocator;
    const port = 6739;
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port);

    const socket = try std.net.tcpConnectToAddress(address);
    defer socket.close();

    // send a command to the server
    const command = "PUT key1 value1\r\n";

    const n = try socket.write(command);

    std.debug.print("Sent {} bytes to server\n", .{n});

    // read the response from the server
    var buffer: [1024]u8 = undefined;
    const bytes_read = try socket.read(&buffer);
    if (bytes_read == 0) {
        std.debug.print("No data read from socket\n", .{});
        return;
    }

    std.debug.print("Read {} bytes from server\n", .{bytes_read});
    const response = buffer[0..bytes_read];
    std.debug.print("Response from server: {s}\n", .{response});
}
