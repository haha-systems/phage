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
const builtin = @import("builtin");

// Configuration constants
const BLOCK_SIZE = 512;
const MAX_ENTRY_SIZE = std.heap.pageSize();
const MAX_IN_FLIGHT: u16 = 1024;
const BATCH_SIZE = 100;
const BUFFER_POOL_SIZE = MAX_IN_FLIGHT * 2;
const INDEX_SHARDS = 16;

const log = std.log.scoped(.phage);

pub const Phage = struct {
    ring: uring,
    fd: std.posix.fd_t,
    fd_index: i32, // Index of the registered file descriptor
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

    pub fn init(allocator: Allocator, path: []const u8, options: struct { use_sqpoll: bool = true }) !*Phage {
        // Allow disabling SQPOLL mode via options
        if (!options.use_sqpoll) {
            log.debug("SQPOLL mode disabled by user request", .{});
            return initStandard(allocator, path);
        }

        // Try to initialize with SQPOLL
        return initWithSqpoll(allocator, path) catch |err| {
            log.warn("SQPOLL initialization failed: {s}, falling back to standard mode", .{@errorName(err)});
            return initStandard(allocator, path);
        };
    }

    fn initStandard(allocator: Allocator, path: []const u8) !*Phage {
        var store = try allocator.create(Phage);
        errdefer allocator.destroy(store);

        // Standard io_uring setup
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_COOP_TASKRUN |
                linux.IORING_SETUP_SINGLE_ISSUER,
        });

        store.ring = try uring.init_params(MAX_IN_FLIGHT, &params);

        // Open the file
        store.fd = try std.posix.open(
            path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        // Try to register files
        var fds = [_]std.posix.fd_t{store.fd};
        if (store.ring.register_files(fds[0..])) |_| {
            store.fd_index = 0;
            log.debug("Successfully registered file descriptor with io_uring", .{});
        } else |err| {
            log.warn("Failed to register files with io_uring: {s}", .{@errorName(err)});
            store.fd_index = -1;
        }

        // Initialize other fields
        const stat_size = try std.posix.fstat(store.fd);
        store.file_size = std.atomic.Value(u64).init(@intCast(stat_size.size));
        store.allocator = allocator;
        store.pending_ops = std.atomic.Value(u32).init(0);
        store.buffer_pool = try BufferPool.init(allocator);
        store.completion_queue = CompletionQueue.init();
        store.index = try IndexManager.init(allocator);
        store.metrics = Metrics.init();

        try store.rebuildIndex();

        log.debug("init complete in standard mode", .{});

        return store;
    }

    fn initWithSqpoll(allocator: Allocator, path: []const u8) !*Phage {
        var store = try allocator.create(Phage);
        errdefer allocator.destroy(store);

        // SQPOLL io_uring setup
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_SQPOLL |
                linux.IORING_SETUP_COOP_TASKRUN |
                linux.IORING_SETUP_SINGLE_ISSUER,
            .sq_thread_idle = 2000, // 2 seconds idle timeout
        });

        store.ring = try uring.init_params(MAX_IN_FLIGHT, &params);
        log.debug("SQPOLL mode initialized successfully", .{});

        // Open the file
        store.fd = try std.posix.open(
            path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        // Try to register files
        var fds = [_]std.posix.fd_t{store.fd};
        if (store.ring.register_files(fds[0..])) |_| {
            store.fd_index = 0;
            log.debug("Successfully registered file descriptor with io_uring", .{});
        } else |err| {
            log.warn("Failed to register files with io_uring: {s}", .{@errorName(err)});
            store.fd_index = -1;
        }

        // Initialize other fields
        const stat_size = try std.posix.fstat(store.fd);
        store.file_size = std.atomic.Value(u64).init(@intCast(stat_size.size));
        store.allocator = allocator;
        store.pending_ops = std.atomic.Value(u32).init(0);
        store.buffer_pool = try BufferPool.init(allocator);
        store.completion_queue = CompletionQueue.init();
        store.index = try IndexManager.init(allocator);
        store.metrics = Metrics.init();

        try store.rebuildIndex();

        log.debug("init complete with SQPOLL: true", .{});

        return store;
    }

    pub fn deinit(store: *Phage) !void {
        // always remember to flush your ring
        const completed = try store.processCompletions();

        if (completed != 0) return error.IncompleteOps;

        // Unregister files before closing, but only if they were registered
        if (store.fd_index >= 0) {
            store.ring.unregister_files() catch |err| {
                log.warn("Failed to unregister files: {}", .{err});
                // Continue with cleanup anyway
            };
        }

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

    /// Calculates the CRC32 of a buffer
    inline fn caclulate_crc32(ptr: anytype, len: usize) u32 {
        var crc: u32 = 0xffffffff;
        for (ptr[0..len]) |byte| {
            crc = std.hash.Crc32.update(byte);
        }
        return crc;
    }

    /// Prefetch function for L1 cache that handles both read and write operations
    pub inline fn prefetch(ptr: anytype, is_write: bool) void {
        // Take address of the pointer directly, which works for any type
        const addr = @intFromPtr(&ptr);

        switch (builtin.cpu.arch) {
            .x86_64, .x86 => {
                if (is_write) {
                    // PREFETCHW for write operations (supported on some x86 CPUs)
                    asm volatile ("prefetchw (%[addr])"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                } else {
                    // PREFETCHT0 for read operations (L1 cache)
                    asm volatile ("prefetcht0 (%[addr])"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                }
            },
            .aarch64, .arm => {
                if (is_write) {
                    // PSTL1KEEP for write operations (prestore to L1)
                    asm volatile ("prfm pstl1keep, [%[addr]]"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                } else {
                    // PLDL1KEEP for read operations (preload to L1)
                    asm volatile ("prfm pldl1keep, [%[addr]]"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                }
            },
            else => {
                // No explicit prefetch on other architectures
                // This function becomes a no-op
            },
        }
    }

    pub fn put(store: *Phage, key: []const u8, value: []const u8) !void {
        // Validate inputs
        if (key.len == 0 or key.len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader)) {
            return error.KeyTooLarge;
        }

        if (value.len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader) - key.len) {
            return error.ValueTooLarge;
        }

        // Prepare header
        const header = EntryHeader{
            .key_len = @intCast(key.len),
            .val_len = @intCast(value.len),
        };

        const total_len = @sizeOf(EntryHeader) + key.len + value.len;

        // Allocate buffer for the entry
        const buf = try store.allocator.alloc(u8, total_len);
        defer store.allocator.free(buf);

        // Copy header and data to buffer
        @memcpy(buf[0..@sizeOf(EntryHeader)], std.mem.asBytes(&header));
        @memcpy(buf[@sizeOf(EntryHeader)..][0..key.len], key);
        @memcpy(buf[@sizeOf(EntryHeader) + key.len ..][0..value.len], value);

        // Write to file
        const offset = store.file_size.fetchAdd(total_len, .monotonic);

        var sqe = try store.ring.get_sqe();
        if (store.fd_index >= 0) {
            // Use registered file descriptor with SQPOLL optimizations
            sqe.prep_write(store.fd_index, buf, offset);
            sqe.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_ASYNC;
        } else {
            // Use regular file descriptor
            sqe.prep_write(store.fd, buf, offset);
        }
        sqe.user_data = @intFromPtr(buf.ptr);

        // Track pending operation
        const pending = PendingIO{
            .id = sqe.user_data,
            .buffer = buf,
            .offset = offset,
            .key = try store.allocator.dupe(u8, key),
            .value = try store.allocator.dupe(u8, value),
            .start_time = std.time.nanoTimestamp(),
            .is_write = true,
        };

        try store.completion_queue.add(store.allocator, pending);
        _ = store.pending_ops.fetchAdd(1, .monotonic);

        // Submit and wait for completion
        _ = try store.ring.submit_and_wait(1);

        // Process completions to ensure the write is complete
        _ = try store.processCompletions();
    }

    pub fn get(store: *Phage, key: []const u8, allocator: Allocator) ![]u8 {
        const start_time = std.time.nanoTimestamp();

        const entry = store.index.get(key) orelse return error.NotFound;

        // Validate entry length before proceeding
        if (entry.len == 0 or entry.len > MAX_ENTRY_SIZE * 2) {
            log.err("Invalid entry length in index: {}", .{entry.len});
            return error.InvalidIndexEntry;
        }

        log.debug("Reading entry at offset {} with length {}", .{ entry.offset, entry.len });

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

        // Log buffer size for debugging
        log.debug("Buffer size: {}", .{buf.len});

        // Ensure buffer is large enough for the entry
        if (buf.len < entry.len) {
            log.err("Buffer too small for entry: needed {}, got {}", .{ entry.len, buf.len });
            return error.BufferTooSmall;
        }

        var sqe = try store.ring.get_sqe();
        if (store.fd_index >= 0) {
            // Use registered file descriptor with SQPOLL optimizations
            sqe.prep_read(store.fd_index, buf[0..entry.len], entry.offset);
            sqe.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_ASYNC;
        } else {
            // Use regular file descriptor
            sqe.prep_read(store.fd, buf[0..entry.len], entry.offset);
        }
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

        _ = try store.ring.submit_and_wait(1); // Using 0 to leverage SQPOLL
        _ = try store.processCompletions();

        // Validate buffer before processing
        if (buf.len < @sizeOf(EntryHeader)) {
            log.err("Buffer too small for header", .{});
            return error.BufferTooSmall;
        }

        // Use a safer approach to extract header values
        var header: EntryHeader = undefined;
        @memcpy(std.mem.asBytes(&header), buf[0..@sizeOf(EntryHeader)]);

        // Log header values for debugging
        log.debug("Header values: key_len={}, val_len={}", .{ header.key_len, header.val_len });

        // Check for unreasonable values that might indicate corruption
        if (header.key_len > 1024 * 1024 or header.val_len > 1024 * 1024) {
            log.err("Suspiciously large header values: key_len={}, val_len={}", .{ header.key_len, header.val_len });
            return error.CorruptHeader;
        }

        // Validate header values to ensure they are within buffer bounds
        if (header.key_len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader) or
            header.val_len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader) - header.key_len)
        {
            log.err("Invalid header values: key_len={}, val_len={}, buffer size={}", .{ header.key_len, header.val_len, buf.len });
            return error.InvalidHeader;
        }

        const value_start = @sizeOf(EntryHeader) + header.key_len;

        // Additional bounds check before accessing buffer
        if (value_start >= buf.len) {
            log.err("Value start position beyond buffer bounds: start={}, buffer size={}", .{ value_start, buf.len });
            return error.BufferBoundsError;
        }

        if (value_start + header.val_len > buf.len) {
            log.err("Buffer bounds error: start={}, len={}, buffer size={}", .{ value_start, header.val_len, buf.len });
            return error.BufferBoundsError;
        }

        // Verify the key with bounds checking
        const stored_key_len = @min(header.key_len, buf.len - @sizeOf(EntryHeader));
        if (stored_key_len == 0) {
            log.err("Invalid stored key length: {}", .{stored_key_len});
            return error.InvalidKeyLength;
        }

        const stored_key = buf[@sizeOf(EntryHeader) .. @sizeOf(EntryHeader) + stored_key_len];

        if (!std.mem.eql(u8, stored_key, key[0..@min(key.len, stored_key_len)])) {
            log.err("Key mismatch: expected '{s}', got '{s}'", .{ key, stored_key });
            return error.KeyMismatch;
        }

        // Copy the value with bounds checking
        const value_copy = try allocator.alloc(u8, header.val_len);
        errdefer allocator.free(value_copy);

        // Extra safety check
        if (value_start + header.val_len <= buf.len) {
            @memcpy(value_copy, buf[value_start..][0..header.val_len]);
        } else {
            // This should never happen due to earlier checks, but just in case
            allocator.free(value_copy);
            log.err("Value extends beyond buffer bounds: start={}, len={}, buffer size={}", .{ value_start, header.val_len, buf.len });
            return error.BufferBoundsError;
        }

        return value_copy;
    }

    pub fn putBatch(store: *Phage, keys: []const []const u8, values: []const []const u8) !void {
        if (keys.len != values.len) return error.BatchSizeMismatch;

        // Limit batch size to prevent overwhelming the io_uring
        const batch_size = @min(keys.len, BATCH_SIZE);
        if (keys.len > batch_size) {
            log.debug("Limiting batch size from {} to {}", .{ keys.len, batch_size });
        }

        // Allocate an array to track pending operations in this batch.
        var pending = try store.allocator.alloc(PendingIO, batch_size);
        defer store.allocator.free(pending);

        const start_time = std.time.nanoTimestamp();
        var total_size: u64 = 0;

        // First pass: Calculate the total batch size.
        for (keys[0..batch_size], values[0..batch_size]) |key, value| {
            const entry_size = @sizeOf(EntryHeader) + key.len + value.len;
            const aligned_size = std.mem.alignForward(usize, entry_size, BLOCK_SIZE);
            total_size += aligned_size;
        }

        // Reserve a contiguous offset range for the batch.
        const batch_offset = store.file_size.fetchAdd(total_size, .monotonic);
        var current_offset = batch_offset;

        // Second pass: Prepare each write in the batch.
        for (keys[0..batch_size], values[0..batch_size], 0..) |key, value, i| {
            // Prefetch next key/value 4 iterations ahead
            if (i + 4 < batch_size) {
                prefetch(keys[i + 4], false);
                prefetch(values[i + 4], false);
            }

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

            // Copy header and data to buffer
            @memcpy(buf[0..@sizeOf(EntryHeader)], std.mem.asBytes(&header));
            @memcpy(buf[@sizeOf(EntryHeader)..][0..key.len], key);
            @memcpy(buf[@sizeOf(EntryHeader) + key.len ..][0..value.len], value);

            // Get an SQE and prepare the write
            var sqe = try store.ring.get_sqe();
            if (store.fd_index >= 0) {
                // Use registered file descriptor with SQPOLL optimizations
                sqe.prep_write(store.fd_index, buf, current_offset);
                sqe.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_ASYNC;
            } else {
                // Use regular file descriptor
                sqe.prep_write(store.fd, buf, current_offset);
            }
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

            // If we have a lot of entries, submit in smaller batches to avoid queue overflow
            if (i % 16 == 15) {
                log.debug("Submitting intermediate batch at entry {}", .{i});
                _ = try store.ring.submit();
                _ = try store.processCompletions();
            }
        }

        // Submit the entire batch
        _ = try store.ring.submit();

        // Process completions until all pending ops from this batch are handled.
        while (store.pending_ops.load(.acquire) > 0) {
            _ = try store.processCompletions();
        }
    }

    fn processCompletions(store: *Phage) !u32 {
        var completed: u32 = 0;
        var cqes: [MAX_IN_FLIGHT]linux.io_uring_cqe = undefined;
        const count = try store.ring.copy_cqes(&cqes, 0);

        if (count == 0) {
            return 0;
        }

        for (cqes[0..count]) |cqe| {
            completed += 1;

            // Check if this is a tracked operation
            const pending = store.completion_queue.complete(cqe);
            if (pending == null) {
                log.debug("Received completion for untracked operation: user_data={}", .{cqe.user_data});
                continue;
            }

            // Check for IO errors
            if (cqe.res < 0) {
                log.err("IO operation failed with error code: {}", .{cqe.res});
                continue;
            }

            // Release buffer and decrement pending ops
            defer {
                store.buffer_pool.release(pending.?.buffer);
                _ = store.pending_ops.fetchSub(1, .monotonic);
            }

            // Record write latency
            if (pending.?.is_write) {
                const end_time = std.time.nanoTimestamp();
                const latency = @as(u64, @intCast(end_time - pending.?.start_time));
                store.metrics.recordWrite(latency);

                // Update index for writes
                if (pending.?.key.len > 0) {
                    const entry = IndexEntry{
                        .offset = pending.?.offset,
                        .len = @intCast(cqe.res),
                        .key = pending.?.key,
                        .value = pending.?.value,
                        .key_allocated = true,
                    };

                    store.index.put(pending.?.key, entry) catch |err| {
                        log.err("Failed to update index: {s}", .{@errorName(err)});
                    };
                }
            } else {
                // Record read latency
                const end_time = std.time.nanoTimestamp();
                const latency = @as(u64, @intCast(end_time - pending.?.start_time));
                store.metrics.recordRead(latency);
            }
        }

        return completed;
    }

    fn rebuildIndex(store: *Phage) !void {
        log.debug("rebuilding index", .{});

        const stat = try std.posix.fstat(store.fd);
        const file_size = @as(u64, @intCast(stat.size));
        store.file_size.store(file_size, .monotonic);

        var offset: u64 = 0;
        const buf = try store.allocator.alloc(u8, MAX_ENTRY_SIZE);
        defer store.allocator.free(buf);

        while (offset < file_size) {
            const bytes_read = try std.posix.pread(store.fd, buf, offset);
            if (bytes_read < @sizeOf(EntryHeader)) {
                break;
            }

            var header: EntryHeader = undefined;
            @memcpy(std.mem.asBytes(&header), buf[0..@sizeOf(EntryHeader)]);

            // Validate header
            if (header.key_len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader) or
                header.val_len > MAX_ENTRY_SIZE - @sizeOf(EntryHeader) - header.key_len)
            {
                log.err("Invalid header at offset {}: key_len={}, val_len={}", .{ offset, header.key_len, header.val_len });
                break;
            }

            const total_len = @sizeOf(EntryHeader) + header.key_len + header.val_len;
            if (total_len > bytes_read) {
                break;
            }

            // Extract key
            const key_start = @sizeOf(EntryHeader);
            const key = buf[key_start .. key_start + header.key_len];

            // Extract value
            const value_start = key_start + header.key_len;
            const value = buf[value_start .. value_start + header.val_len];
            if (value.len == 0) {
                log.err("Empty value at offset {}", .{offset});
                break;
            }

            // Add to index
            const entry = IndexEntry{
                .offset = offset,
                .len = @intCast(total_len),
                .key_allocated = false,
                .key = key,
                .value = value,
            };

            try store.index.put(key, entry);

            offset += total_len;
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
