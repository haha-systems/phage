const std = @import("std");
const AtomicStack = @import("atomic_stack.zig").AtomicStack;
const Allocator = std.mem.Allocator;

const BUFFER_POOL_SIZE = std.mem.page_size;
const BLOCK_SIZE = std.mem.page_size;
const MAX_ENTRY_SIZE = std.mem.page_size;

// stack of buffers for I/O
pub const BufferPool = struct {
    buffers: [][]u8,
    available: AtomicStack,
    buffer_pool_size: usize,
    block_size: usize,

    pub fn init(allocator: Allocator) !BufferPool {
        const buffers = try allocator.alloc([]u8, BUFFER_POOL_SIZE);
        var available = AtomicStack{
            .mutex = std.Thread.Mutex{},
            .list = std.ArrayList([]u8).init(allocator),
        };

        try available.list.ensureTotalCapacity(BUFFER_POOL_SIZE);

        for (buffers) |*buffer| {
            buffer.* = try allocator.alignedAlloc(u8, BLOCK_SIZE, MAX_ENTRY_SIZE);
            available.list.appendAssumeCapacity(buffer.*);
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
        return self.available.list.popOrNull();
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
