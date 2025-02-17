const std = @import("std");
const PendingIO = @import("io.zig").PendingIO;

pub const CompletionQueue = struct {
    entries: std.AutoHashMapUnmanaged(u64, PendingIO),
    mutex: std.Thread.Mutex,

    pub fn init() CompletionQueue {
        return .{
            .entries = .{},
            .mutex = .{},
        };
    }

    pub fn add(self: *CompletionQueue, allocator: std.mem.Allocator, entry: PendingIO) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.entries.put(allocator, entry.id, entry);
    }

    pub fn complete(self: *CompletionQueue, cqe: std.os.linux.io_uring_cqe) ?PendingIO {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.fetchRemove(cqe.user_data);
        return entry.?.value;
    }

    pub fn deinit(self: *CompletionQueue, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};
