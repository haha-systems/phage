// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
const mem = std.mem;

/// A simple generic ring buffer implementation.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize,
        tail: usize,
        size: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);

            return Self{
                .buffer = buffer,
                .head = 0,
                .tail = 0,
                .size = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
            self.buffer = &[_]T{};
        }

        pub fn push(self: *Self, data: []const T) !void {
            if (data.len > self.size - self.head) {
                return error.BufferOverflow;
            }

            mem.copyForwards(T, self.buffer[self.head..], data);
            self.head += data.len;
        }

        pub fn pop(self: *Self, size: usize) ![]T {
            if (size > self.head - self.tail) {
                return error.BufferUnderflow;
            }

            const data = self.buffer[self.tail .. self.tail + size];
            self.tail += size;
            return data;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head == self.tail;
        }

        pub fn isFull(self: *Self) bool {
            return self.head == self.size;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }

        pub fn length(self: *Self) usize {
            return self.head - self.tail;
        }

        pub fn remaining(self: *Self) usize {
            return self.size - self.length();
        }

        pub fn peek(self: *Self) []T {
            return self.buffer[self.tail..self.head];
        }

        pub fn resize(self: *Self, allocator: std.mem.Allocator, new_size: usize) !void {
            if (new_size < self.length()) {
                return error.BufferTooSmall;
            }

            const new_buffer = try allocator.alloc(T, new_size);
            mem.copyForwards(T, new_buffer, self.buffer[self.tail..self.head]);

            // Free the old buffer now that we have copied the data.
            allocator.free(self.buffer);

            self.buffer = new_buffer;
            self.size = new_size;
            self.head = self.length();
            self.tail = 0;
        }
    };
}

test "RingBuffer" {
    const allocator = std.testing.allocator;
    const buffer_size = 1024;

    var ring_buffer = RingBuffer(u8).init(allocator, buffer_size) catch |err| {
        std.debug.print("Error initializing ring buffer: {}\n", .{err});
        return err;
    };
    defer ring_buffer.deinit(allocator);
    errdefer ring_buffer.deinit(allocator);

    const data = "Hello, World!";
    try ring_buffer.push(data);

    try std.testing.expectEqual(data.len, ring_buffer.length());

    const popped_data = try ring_buffer.pop(data.len);
    try std.testing.expectEqualStrings(data, popped_data);

    const is_empty = ring_buffer.isEmpty();
    try std.testing.expectEqual(true, is_empty);

    const length = ring_buffer.length();
    try std.testing.expectEqual(0, length);

    const is_full = ring_buffer.isFull();
    try std.testing.expectEqual(false, is_full);

    ring_buffer.clear();
    try std.testing.expectEqual(0, ring_buffer.length());
    try std.testing.expectEqual(true, ring_buffer.isEmpty());
    try std.testing.expectEqual(false, ring_buffer.isFull());

    const more_data = "More data!";
    try ring_buffer.push(more_data);

    const peeked_data = ring_buffer.peek();
    try std.testing.expectEqualStrings(more_data, peeked_data);

    const remaining = ring_buffer.remaining();
    try std.testing.expectEqual(ring_buffer.size - more_data.len, remaining);

    try ring_buffer.resize(allocator, buffer_size * 2);
    try std.testing.expectEqual(buffer_size * 2, ring_buffer.size);
    try std.testing.expectEqual(buffer_size * 2 - more_data.len, ring_buffer.remaining());

    try ring_buffer.push("Even more data!");

    const resized_peeked_data = ring_buffer.peek();
    try std.testing.expectEqualStrings("More data!Even more data!", resized_peeked_data);

    ring_buffer.clear();
    try std.testing.expectEqual(0, ring_buffer.length());
}
