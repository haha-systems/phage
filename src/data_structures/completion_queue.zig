// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

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

        // Check if the entry exists and handle the case where it doesn't
        const entry = self.entries.fetchRemove(cqe.user_data);
        if (entry == null) {
            // In SQPOLL mode, we might get completions for operations we've already processed
            // or for operations that were registered with a different ID
            return null;
        }

        return entry.?.value;
    }

    pub fn deinit(self: *CompletionQueue, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};
