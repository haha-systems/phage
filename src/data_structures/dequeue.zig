const std = @import("std");
const mem = @import("std").mem;

/// A double-ended queue (deque) implementation.
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []T,
        head: usize,
        tail: usize,
        size: usize,
        capacity: usize,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .buffer = &[_]T{},
                .head = 0,
                .tail = 0,
                .size = 0,
                .capacity = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.buffer = &[_]T{};
        }

        pub fn pushHead(self: *Self, value: T) !void {
            if (self.size == self.capacity) {
                return error.DequeOverflow;
            }

            if (self.head == 0) {
                self.head = self.capacity - 1;
            } else {
                self.head -= 1;
            }

            self.buffer[self.head] = value;
            self.size += 1;
        }

        pub fn pushTail(self: *Self, value: T) !void {
            if (self.size == self.capacity) {
                return error.DequeOverflow;
            }

            self.buffer[self.tail] = value;
            self.tail += 1;
            if (self.tail == self.capacity) {
                self.tail = 0;
            }
            self.size += 1;
        }
    };
}
