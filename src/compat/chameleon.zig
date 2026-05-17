const std = @import("std");

pub fn initRuntime(options: anytype) Runtime {
    return .{
        .allocator = options.allocator,
        .owned = std.array_list.Managed([]u8).init(options.allocator),
    };
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    owned: std.array_list.Managed([]u8),

    pub fn deinit(self: *Runtime) void {
        for (self.owned.items) |item| {
            self.allocator.free(item);
        }
        self.owned.deinit();
    }

    pub fn red(self: *Runtime) Color {
        return .{ .runtime = self };
    }

    pub fn redBright(self: *Runtime) Color {
        return .{ .runtime = self };
    }
};

pub const Color = struct {
    runtime: *Runtime,

    pub fn fmt(self: Color, comptime format: []const u8, args: anytype) ![]const u8 {
        const rendered = try std.fmt.allocPrint(self.runtime.allocator, format, args);
        errdefer self.runtime.allocator.free(rendered);
        try self.runtime.owned.append(rendered);
        return rendered;
    }
};
