const std = @import("std");
const os = std.os;
const linux = os.linux;
const uring = linux.IoUring;
const Allocator = std.mem.Allocator;
const BufferPool = @import("buffer_pool.zig").BufferPool;
const StringContext = @import("string_context.zig").StringContext;
const Metrics = @import("metrics.zig").Metrics;
const IndexManager = @import("index.zig").IndexManager;
const IndexEntry = @import("index.zig").IndexEntry;
const CompletionQueue = @import("completion_queue.zig").CompletionQueue;
const PendingIO = @import("io.zig").PendingIO;

// Configuration constants
const BLOCK_SIZE = 512;
const MAX_ENTRY_SIZE = std.mem.page_size;
const MAX_IN_FLIGHT: u16 = 1024;
const BATCH_SIZE = 100;
const BUFFER_POOL_SIZE = MAX_IN_FLIGHT * 2;
const INDEX_SHARDS = 16;

const log = std.log.scoped(.phage);

pub const Phage = struct {
    ring: uring,
    fd: std.posix.fd_t,
    index: IndexManager,
    file_size: std.atomic.Value(u64),
    allocator: Allocator,
    pending_ops: std.atomic.Value(u32),
    buffer_pool: BufferPool,
    completion_queue: CompletionQueue,
    metrics: Metrics,

    const EntryHeader = extern struct {
        key_len: u32 align(1),
        val_len: u32 align(1),

        comptime {
            if (@sizeOf(@This()) != 8) @compileError("invalid header size");
        }
    };

    pub fn init(allocator: Allocator, path: []const u8) !*Phage {
        var store = try allocator.create(Phage);
        errdefer allocator.destroy(store);

        // Initialize io_uring with optimal parameters
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_COOP_TASKRUN |
                linux.IORING_SETUP_SINGLE_ISSUER,
            .sq_thread_idle = 2000,
        });

        store.ring = try uring.init_params(MAX_IN_FLIGHT, &params);
        store.fd = try std.posix.open(
            path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        const stat_size = try std.posix.fstat(store.fd);
        store.file_size = std.atomic.Value(u64).init(@intCast(stat_size.size));
        store.allocator = allocator;
        store.pending_ops = std.atomic.Value(u32).init(0);
        store.buffer_pool = try BufferPool.init(allocator);
        store.completion_queue = CompletionQueue.init();
        store.index = try IndexManager.init(allocator);
        store.metrics = Metrics.init();

        try store.rebuildIndex();

        log.debug("init complete", .{});

        return store;
    }

    pub fn deinit(store: *Phage) !void {
        // always remember to flush your ring
        const completed = try store.processCompletions();

        if (completed != 0) return error.IncompleteOps;

        // close io_uring and file descriptor first
        store.ring.deinit();
        _ = std.posix.close(store.fd);

        // cleanup index
        store.index.deinit(store.allocator);

        // cleanup buffer pool
        store.buffer_pool.deinit(store.allocator);

        // cleanup completion queue
        store.completion_queue.deinit(store.allocator);

        // finally free the store itself
        store.allocator.destroy(store);
    }

    pub fn put(store: *Phage, key: []const u8, value: []const u8) !void {
        // entry validation
        if (key.len == 0 or key.len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader)) {
            return error.InvalidKeySize;
        }

        const start_time = std.time.nanoTimestamp();

        // Prepare the entry header
        const header = EntryHeader{
            .key_len = @intCast(key.len),
            .val_len = @intCast(value.len),
        };

        const total_len = @sizeOf(EntryHeader) + key.len + value.len;
        const aligned_len = std.mem.alignForward(usize, total_len, BLOCK_SIZE);

        // Get buffer from pool
        const buf = blk: {
            var retries: u8 = 0;
            while (retries < 10) : (retries += 1) {
                if (store.buffer_pool.acquire()) |buf| {
                    break :blk buf;
                }
                _ = try store.processCompletions();
                std.time.sleep(1 * std.time.ns_per_us);
            }
            log.debug("no buffers after {d} tries", .{retries});
            return error.NoBufferAvailable;
        };
        errdefer store.buffer_pool.release(buf);

        // Prepare buffer contents
        std.mem.copyForwards(u8, buf[0..8], std.mem.asBytes(&header));
        std.mem.copyForwards(u8, buf[8..][0..key.len], key);
        std.mem.copyForwards(u8, buf[8 + key.len ..][0..value.len], value);

        const offset = store.file_size.fetchAdd(aligned_len, .monotonic);

        var sqe = try store.ring.get_sqe();
        sqe.prep_write(store.fd, buf, offset);
        sqe.user_data = @intFromPtr(buf.ptr);

        // Track pending operation
        const pending = PendingIO{
            .id = sqe.user_data,
            .buffer = buf,
            .offset = offset,
            .key = try store.allocator.dupe(u8, key),
            .value = try store.allocator.dupe(u8, value),
            .start_time = start_time,
            .is_write = true,
        };

        try store.completion_queue.add(store.allocator, pending);
        _ = store.pending_ops.fetchAdd(1, .monotonic);

        // Submit without waiting
        _ = try store.ring.submit_and_wait(1);

        // Process any ready completions
        _ = try store.processCompletions();
    }

    pub fn get(store: *Phage, key: []const u8, allocator: Allocator) ![]u8 {
        const start_time = std.time.nanoTimestamp();

        const entry = store.index.get(key) orelse return error.NotFound;

        const buf = blk: {
            var retries: u8 = 0;
            while (retries < 3) : (retries += 1) {
                if (store.buffer_pool.acquire()) |buf| {
                    break :blk buf;
                }
                _ = try store.processCompletions();
            }
            return error.NoBufferAvailable;
        };
        defer store.buffer_pool.release(buf);

        var sqe = try store.ring.get_sqe();
        sqe.prep_read(store.fd, buf[0..entry.len], entry.offset);
        sqe.user_data = @intFromPtr(buf.ptr);

        const pending = PendingIO{
            .id = sqe.user_data,
            .buffer = buf,
            .offset = entry.offset,
            .key = key,
            .value = undefined,
            .start_time = start_time,
            .is_write = false,
        };

        try store.completion_queue.add(store.allocator, pending);
        _ = store.pending_ops.fetchAdd(1, .monotonic);

        _ = try store.ring.submit_and_wait(1);
        _ = try store.processCompletions();

        const header = std.mem.bytesToValue(EntryHeader, buf[0..8]);
        const value_start = 8 + header.key_len;
        return try allocator.dupe(u8, buf[value_start..][0..header.val_len]);
    }

    pub fn putBatch(store: *Phage, keys: []const []const u8, values: []const []const u8) !void {
        if (keys.len != values.len) return error.BatchSizeMismatch;
        if (keys.len > BATCH_SIZE) return error.BatchTooLarge;

        // Allocate an array to track pending operations in this batch.
        var pending = try store.allocator.alloc(PendingIO, keys.len);
        defer store.allocator.free(pending);

        const start_time = std.time.nanoTimestamp();
        var total_size: u64 = 0;

        // First pass: Calculate the total batch size.
        for (keys, values) |key, value| {
            const entry_size = @sizeOf(EntryHeader) + key.len + value.len;
            const aligned_size = std.mem.alignForward(usize, entry_size, BLOCK_SIZE);
            total_size += aligned_size;
        }

        // Reserve a contiguous offset range for the batch.
        const batch_offset = store.file_size.fetchAdd(total_size, .monotonic);
        var current_offset = batch_offset;

        // Second pass: Prepare each write in the batch.
        for (keys, values, 0..) |key, value, i| {
            const header = EntryHeader{
                .key_len = @intCast(key.len),
                .val_len = @intCast(value.len),
            };

            // Acquire a buffer from the pool with retry logic.
            const buf = blk: {
                var retries: u8 = 0;
                while (retries < 10) : (retries += 1) {
                    if (store.buffer_pool.acquire()) |b| {
                        break :blk b;
                    }
                    _ = try store.processCompletions();
                    std.time.sleep(1 * std.time.ns_per_us);
                }
                return error.NoBufferAvailable;
            };
            errdefer store.buffer_pool.release(buf);

            const total_len = @sizeOf(EntryHeader) + key.len + value.len;
            const aligned_len = std.mem.alignForward(usize, total_len, BLOCK_SIZE);

            // Fill the buffer with header, key, and value.
            std.mem.copyForwards(u8, buf[0..8], std.mem.asBytes(&header));
            std.mem.copyForwards(u8, buf[8..][0..key.len], key);
            std.mem.copyForwards(u8, buf[8 + key.len ..][0..value.len], value);

            // Get an SQE and prepare the write.
            var sqe = try store.ring.get_sqe();
            sqe.prep_write(store.fd, buf, current_offset);
            sqe.user_data = @intFromPtr(buf.ptr);

            // Record this pending operation.
            pending[i] = .{
                .id = sqe.user_data,
                .buffer = buf,
                .offset = current_offset,
                .key = try store.allocator.dupe(u8, key),
                .value = try store.allocator.dupe(u8, value),
                .start_time = start_time,
                .is_write = true,
            };

            // Add to the completion queue and increment pending_ops.
            try store.completion_queue.add(store.allocator, pending[i]);
            _ = store.pending_ops.fetchAdd(1, .monotonic);

            current_offset += aligned_len;
        }

        // Submit the entire batch.
        _ = try store.ring.submit();

        // Process completions until all pending ops from this batch are handled.
        while (store.pending_ops.load(.acquire) > 0) {
            _ = try store.processCompletions();
        }
    }

    fn processCompletions(store: *Phage) !usize {
        var cqes: [MAX_IN_FLIGHT]linux.io_uring_cqe = undefined;
        const count = try store.ring.copy_cqes(cqes[0..], 0);

        var completed: usize = 0;

        for (cqes[0..count]) |cqe| {
            if (cqe.res < 0) {
                log.err("IO operation failed: {}", .{cqe.res});
                continue;
            }

            if (store.completion_queue.complete(cqe)) |pending| {
                defer {
                    // always release the buffer when we're done
                    store.buffer_pool.release(pending.buffer);
                    _ = store.pending_ops.fetchSub(1, .monotonic);
                }

                const end_time = std.time.nanoTimestamp();
                const latency = @as(u64, @intCast(end_time - pending.start_time));

                if (pending.is_write) {
                    // handle write completion
                    store.metrics.recordWrite(latency);

                    // update index for writes
                    store.index.put(store.allocator, pending.key, .{
                        .offset = pending.offset,
                        .len = @intCast(pending.buffer.len),
                        .key_allocated = true,
                    }) catch |err| {
                        log.err("failed to update index for key '{s}': {s}", .{ pending.key, @errorName(err) });
                    };
                } else {
                    store.metrics.recordRead(latency);
                }

                // free pending op resources
                if (pending.is_write) {
                    store.allocator.free(pending.key);
                    store.allocator.free(pending.value);
                }
            }

            completed += 1;
        }

        return completed;
    }

    fn rebuildIndex(store: *Phage) !void {
        log.debug("rebuilding index", .{});

        var offset: u64 = 0;
        const file_size = store.file_size.load(.monotonic);

        while (offset < file_size) {
            const buf = blk: {
                var retries: u8 = 0;
                while (retries < 3) : (retries += 1) {
                    if (store.buffer_pool.acquire()) |buf| {
                        break :blk buf;
                    }
                    _ = try store.processCompletions();
                }
                return error.NoBufferAvailable;
            };
            defer store.buffer_pool.release(buf);

            var sqe = try store.ring.get_sqe();
            sqe.prep_read(store.fd, buf, offset);
            sqe.user_data = @intFromPtr(buf.ptr);

            _ = try store.ring.submit_and_wait(1);
            const cqe = try store.ring.copy_cqe();

            if (cqe.res < 0) return error.IOError;

            // Read and validate header
            if (cqe.res < @sizeOf(EntryHeader)) return error.InvalidData;

            const header = std.mem.bytesToValue(EntryHeader, buf[0..@sizeOf(EntryHeader)]);
            const total_len = @sizeOf(EntryHeader) + header.key_len + header.val_len;

            if (total_len > MAX_ENTRY_SIZE) return error.EntryTooLarge;

            // Extract key
            const key_start = @sizeOf(EntryHeader);
            const key = buf[key_start .. key_start + header.key_len];

            // Store in index
            const key_copy = try store.allocator.dupe(u8, key);
            errdefer store.allocator.free(key_copy);

            try store.index.put(store.allocator, key_copy, .{
                .offset = offset,
                .len = @intCast(total_len),
                .key_allocated = true,
            });

            // Advance to next entry
            const aligned_len = std.mem.alignForward(usize, total_len, BLOCK_SIZE);
            if (aligned_len != cqe.res) {
                log.warn("Alignment mismatch at offset {}", .{offset});
            }

            offset += aligned_len;
        }

        log.debug("index rebuild complete", .{});
    }

    pub const Iterator = struct {
        store: *Phage,
        shard_idx: usize = 0,
        inner_it: ?std.HashMapUnmanaged([]const u8, IndexEntry, StringContext, std.hash_map.default_max_load_percentage).Iterator = null,

        pub fn next(self: *Iterator) ?struct { key: []const u8, entry: IndexEntry } {
            while (true) {
                if (self.inner_it) |*it| {
                    if (it.next()) |entry| {
                        return .{ .key = entry.key_ptr.*, .entry = entry.value_ptr.* };
                    }
                }

                if (self.shard_idx >= self.store.index.shards.len) return null;

                const shard = &self.store.index.shards[self.shard_idx];
                shard.mutex.lock();
                self.inner_it = shard.map.iterator();
                shard.mutex.unlock();
                self.shard_idx += 1;
            }
        }
    };

    pub fn iterator(store: *Phage) Iterator {
        return .{ .store = store };
    }
};
