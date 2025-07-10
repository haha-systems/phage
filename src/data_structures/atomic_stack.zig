// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");

/// AtomicStack provides a very simple mutex-protected stack structure.
pub const AtomicStack = struct {
    mutex: std.Thread.Mutex = .{}, // Store by value, not pointer
    list: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AtomicStack {
        return AtomicStack{
            .list = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AtomicStack) void {
        self.list.deinit();
    }

    pub fn push(self: *AtomicStack, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.list.append(value);
    }

    /// Pop a value from the stack. Caller owns the returned slice.
    pub fn pop(self: *AtomicStack) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.list.items.len == 0) {
            return null;
        }

        // Pop the last value from the stack.
        const value = self.list.pop();
        if (value == null) {
            return null;
        }

        // Copy the value to a new slice to avoid leaking internal pointers.
        return try self.list.allocator.dupe(
            u8,
            value.?,
        );
    }

    /// Peek at the top value of the stack without removing it.
    pub fn peek(self: *AtomicStack) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.list.items.len == 0) {
            return null;
        }

        return self.list.getLastOrNull();
    }

    /// Check if the stack is empty.
    pub fn isEmpty(self: *AtomicStack) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.list.items.len == 0;
    }

    /// Get the length of the stack.
    pub fn len(self: *AtomicStack) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.list.items.len;
    }

    /// Clear the stack and invalidate the underlying pointers.
    pub fn clear(self: *AtomicStack) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.list.clearAndFree();
    }

    /// Convert the stack to an owned slice.
    /// This is a copy of the stack's contents at the time of the call.
    /// The original stack is unaltered.
    /// The caller is responsible for freeing the slice.
    pub fn toOwnedSlice(self: *AtomicStack) !?[][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.list.items.len == 0) {
            return null;
        }

        // Copy the contents of the stack to a new slice.
        // We need to do this because if we use .toOwnedSlice()
        // directly on the list, it will clear and invalidate the pointers.
        var slice = std.ArrayList([]const u8).init(self.list.allocator);
        for (self.list.items) |item| {
            try slice.append(item);
        }

        const owned_slice = try slice.toOwnedSlice();
        slice.deinit(); // Deinitialize the temporary list

        return owned_slice;
    }
};

test "AtomicStack" {
    const allocator = std.testing.allocator;
    var stack = try AtomicStack.init(allocator);
    defer stack.deinit();

    try stack.push("Hello");
    try stack.push("World");

    const top = try stack.peek();
    try std.testing.expectEqualStrings("World", top.?);

    const popped = try stack.pop();
    defer allocator.free(popped.?);
    try std.testing.expectEqualStrings("World", popped.?);

    const is_empty = stack.isEmpty();
    try std.testing.expect(!is_empty);

    const length = stack.len();
    try std.testing.expect(length == 1);

    const owned_slice = try stack.toOwnedSlice() orelse unreachable;
    try std.testing.expectEqualStrings("Hello", owned_slice[0]);
    defer allocator.free(owned_slice);
    errdefer allocator.free(owned_slice);

    stack.clear();
    try std.testing.expectEqual(0, stack.len());
    try std.testing.expectEqual(true, stack.isEmpty());
}
