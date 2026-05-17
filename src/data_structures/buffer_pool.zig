// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
const AtomicStack = @import("atomic_stack.zig").AtomicStack;
const Allocator = std.mem.Allocator;
const IO = @import("../io/io.zig").IO;

const BUFFER_POOL_SIZE = 1;
const BLOCK_SIZE = 4096; // Default block size, can be adjusted as needed
const MAX_ENTRY_SIZE = 4096; // Default max entry size, can be adjusted as needed

// stack of buffers for I/O
pub const BufferPool = struct {
    buffers: [][]u8 align(@alignOf(u8)),
    pool: AtomicStack,
    buffer_pool_size: usize,
    block_size: usize,

    pub fn init(allocator: Allocator) !BufferPool {
        var pool = try AtomicStack.init(allocator);
        try pool.list.ensureTotalCapacity(BUFFER_POOL_SIZE);

        const buffers = try allocator.alloc([]u8, BUFFER_POOL_SIZE);

        for (0..BUFFER_POOL_SIZE) |i| {
            buffers[i] = try allocator.alloc(u8, MAX_ENTRY_SIZE);
            pool.list.appendAssumeCapacity(buffers[i]);
        }

        return BufferPool{
            .buffers = buffers,
            .pool = pool,
            .buffer_pool_size = BUFFER_POOL_SIZE,
            .block_size = BLOCK_SIZE,
        };
    }

    pub fn deinit(self: *BufferPool, allocator: Allocator) void {
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();

        // Free all pre-allocated buffers (even if still in use)
        for (self.buffers) |buffer| {
            allocator.free(buffer); // Free each buffer directly
        }
        allocator.free(self.buffers); // Free the array holding buffer pointers

        // Clear the pool list (no need to free items—they were in self.buffers)
        self.pool.list.deinit();
    }

    pub fn acquire(self: *BufferPool) ?[]u8 {
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();

        if (self.pool.list.pop()) |buffer| {
            if (self.pool.list.items.len > 0) {
                IO.prefetch(self.pool.list.items[0], false);
            }
            return buffer;
        }

        return null;
    }

    pub fn release(self: *BufferPool, buffer: []u8) !void {
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();

        // Check if the buffer is already in the pool
        for (self.pool.list.items) |item| {
            const eql = std.mem.eql(u8, item, buffer);
            if (eql) {
                return; // Buffer is already in the pool, no need to add it again
            }
        }

        // Add the buffer back to the pool list
        try self.pool.list.append(buffer);
        if (self.pool.list.items.len > 0) {
            IO.prefetch(self.pool.list.items[0], false);
        }
    }
};
