const std = @import("std");
const AtomicStack = @import("atomic_stack.zig").AtomicStack;
const Allocator = std.mem.Allocator;
const prefetch = @import("root.zig").Phage.prefetch;

const BUFFER_POOL_SIZE = std.heap.pageSize();
const BLOCK_SIZE = std.heap.pageSize();
const MAX_ENTRY_SIZE = std.heap.pageSize();

// stack of buffers for I/O
pub const BufferPool = struct {
    buffers: [][]align(BLOCK_SIZE) u8,
    available: AtomicStack,
    buffer_pool_size: usize,
    block_size: usize,

    pub fn init(allocator: Allocator) !BufferPool {
        var available = AtomicStack{
            .mutex = std.Thread.Mutex{},
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

    pub fn acquire(self: *BufferPool) ?[]u8 {
        self.available.mutex.lock();
        defer self.available.mutex.unlock();

        if (self.available.list.pop()) |buffer| {
            if (self.available.list.items.len > 0) {
                prefetch(self.available.list.items[0], false);
            }
            return buffer;
        }

        return null;
    }

    pub fn release(self: *BufferPool, buffer: []u8) void {
        self.available.mutex.lock();
        defer self.available.mutex.unlock();
        self.available.list.append(buffer) catch unreachable;
    }

    pub fn deinit(self: *BufferPool, allocator: Allocator) void {
        self.available.mutex.lock();
        defer self.available.mutex.unlock();

        self.available.list.deinit();

        for (self.buffers) |buffer| {
            allocator.free(buffer);
        }
        allocator.free(self.buffers);
    }
};
