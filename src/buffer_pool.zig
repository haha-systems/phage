// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
const AtomicStack = @import("atomic_stack.zig").AtomicStack;
const Allocator = std.mem.Allocator;
const IO = @import("io.zig").IO;

const BUFFER_POOL_SIZE = 1;
const BLOCK_SIZE = std.heap.pageSize();
const MAX_ENTRY_SIZE = std.heap.pageSize();

// stack of buffers for I/O
pub const BufferPool = struct {
    buffers: [][]align(BLOCK_SIZE) u8,
    available: AtomicStack,
    buffer_pool_size: usize,
    block_size: usize,

    pub fn init(allocator: Allocator) !BufferPool {
        var mutex = std.Thread.Mutex{};
        var available = AtomicStack{
            .mutex = &mutex,
            .list = std.ArrayList([]u8).init(allocator),
        };

        try available.list.ensureTotalCapacity(BUFFER_POOL_SIZE);

        const buffers = try allocator.alloc([]align(BLOCK_SIZE) u8, BUFFER_POOL_SIZE);

        for (0..BUFFER_POOL_SIZE) |i| {
            buffers[i] = try allocator.alignedAlloc(u8, BLOCK_SIZE, MAX_ENTRY_SIZE);
            available.list.appendAssumeCapacity(buffers[i]);
        }

        return BufferPool{
            .buffers = buffers,
            .available = available,
            .buffer_pool_size = BUFFER_POOL_SIZE,
            .block_size = BLOCK_SIZE,
        };
    }

    pub fn deinit(self: BufferPool, allocator: Allocator) void {
        self.available.mutex.lock();
        defer self.available.mutex.unlock();

        // Free all pre-allocated buffers (even if still in use)
        for (self.buffers) |buffer| {
            allocator.free(buffer); // Free each buffer directly
        }
        allocator.free(self.buffers); // Free the array holding buffer pointers

        // Clear the available list (no need to free items—they were in self.buffers)
        self.available.list.deinit();
    }

    pub fn acquire(self: *BufferPool) ?[]u8 {
        self.available.mutex.lock();
        defer self.available.mutex.unlock();

        if (self.available.list.pop()) |buffer| {
            if (self.available.list.items.len > 0) {
                IO.prefetch(self.available.list.items[0], false);
            }
            return buffer;
        }

        return null;
    }

    pub fn release(self: *BufferPool, buffer: []u8) !void {
        self.available.mutex.lock();
        defer self.available.mutex.unlock();

        // Check if the buffer is already in the pool
        for (self.available.list.items) |item| {
            const eql = std.mem.eql(u8, item, buffer);
            if (eql) {
                return; // Buffer is already in the pool, no need to add it again
            }
        }

        // Add the buffer back to the available list
        try self.available.list.append(buffer);
        if (self.available.list.items.len > 0) {
            IO.prefetch(self.available.list.items[0], false);
        }
    }
};
