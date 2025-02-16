const std = @import("std");
const os = std.os;
const linux = os.linux;
const uring = linux.IoUring;
const Allocator = std.mem.Allocator;

const BLOCK_SIZE = std.mem.page_size;
const MAX_ENTRY_SIZE = 1024 * 1024;
const MAX_IN_FLIGHT: u16 = 1024;

const log = std.log.scoped(.phage);

pub const Phage = struct {
    ring: uring,
    fd: std.posix.fd_t,
    index: std.StringHashMapUnmanaged(IndexEntry),
    file_size: u64,
    allocator: Allocator,
    pending_ops: std.atomic.Value(u32),
    pending_buffers: std.AutoHashMapUnmanaged(u64, PendingIO),
    index_mutex: std.Thread.Mutex,
    completion_mutex: std.Thread.Mutex,

    const PutResult = struct {
        completion: std.Thread.ResetEvent = .{},
        err: ?anyerror = null,
    };

    const PendingIO = struct {
        buf: []u8,
        offset: u64,
        key: []const u8,
        value: []const u8,
        result: *PutResult,
    };

    const EntryHeader = extern struct {
        key_len: u32 align(1),
        val_len: u32 align(1),

        comptime {
            if (@sizeOf(@This()) != 8) @compileError("phage: invalid header size");
        }
    };

    const IndexEntry = struct {
        offset: usize,
        len: u32,
        key_allocated: bool, // true iff key slize was allocated via dupe
    };

    pub fn init(allocator: Allocator, path: []const u8) !*Phage {
        log.debug("Initializing new store at '{s}'", .{path});

        var store = try allocator.create(Phage);
        errdefer {
            log.err("Failed to initialize store", .{});
            allocator.destroy(store);
        }

        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER,
            .sq_thread_idle = 2000,
        });

        store.ring = try uring.init_params(MAX_IN_FLIGHT, &params);
        store.fd = try std.posix.open(
            path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .TRUNC = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );

        const stat_size = try std.posix.fstat(store.fd);
        log.debug("store size: {d}", .{stat_size.size});

        store.file_size = @intCast((try std.posix.fstat(store.fd)).size);
        store.allocator = allocator;
        store.pending_ops = std.atomic.Value(u32).init(0);
        store.pending_buffers = .{};
        store.index = .{};
        store.index_mutex = .{};
        store.completion_mutex = .{};

        log.debug("IO_uring initialized with params: {any}", .{params});
        log.info("Opened data file (size: {d} bytes)", .{store.file_size});

        try store.rebuildIndex();

        log.info("Index rebuilt with {d} entries", .{store.index.count()});

        return store;
    }

    pub fn rebuildIndex(store: *Phage) !void {
        log.info("Rebuilding index from file...", .{});

        var offset: u64 = 0;
        const alloc = std.heap.page_allocator;
        var entry_count: usize = 0;

        while (offset < store.file_size) {
            log.debug("Processing offset {d}", .{offset});

            const header_buf = try alloc.alignedAlloc(u8, BLOCK_SIZE, BLOCK_SIZE);
            defer alloc.free(header_buf);

            var header_sqe = try store.ring.get_sqe();
            header_sqe.prep_read(store.fd, header_buf, offset);
            header_sqe.user_data = offset;

            _ = try store.ring.submit();
            const header_cqe = try store.ring.copy_cqe();
            if (header_cqe.res < 0) {
                log.err("Header read failed at offset {d}: {any}", .{ offset, linux.E.init(@intCast(-header_cqe.res)) });
                return error.ReadFailed;
            }

            const header = std.mem.bytesToValue(EntryHeader, header_buf[0..8]);
            log.debug("Read header: key_len={d}, val_len={d}", .{ header.key_len, header.val_len });

            const total_len = @sizeOf(EntryHeader) + header.key_len + header.val_len;
            const aligned_len = std.mem.alignForward(usize, total_len, BLOCK_SIZE);

            // Read full entry
            const entry_buf = try alloc.alignedAlloc(u8, BLOCK_SIZE, aligned_len);
            defer alloc.free(entry_buf);

            var full_sqe = try store.ring.get_sqe();
            full_sqe.prep_read(store.fd, entry_buf, offset);
            full_sqe.user_data = offset;

            _ = try store.ring.submit_and_wait(256);
            const full_cqe = try store.ring.copy_cqe();
            if (full_cqe.res < 0) return error.ReadFailed;

            const key = entry_buf[8..][0..header.key_len];

            store.index_mutex.lock();
            defer store.index_mutex.unlock();
            try store.index.put(store.allocator, key, .{
                .offset = offset,
                .len = @intCast(total_len),
                .key_allocated = false,
            });

            entry_count += 1;
            offset += aligned_len;
        }

        log.info("Index rebuild complete. Processed {d} entries", .{entry_count});
    }

    pub fn put(store: *Phage, key: []const u8, value: []const u8) !void {
        log.debug("PUT request for key '{s}' (value len: {d})", .{ key, value.len });

        const result = try store.allocator.create(PutResult);
        defer store.allocator.destroy(result);
        result.* = .{};

        const header = EntryHeader{
            .key_len = @intCast(key.len),
            .val_len = @intCast(value.len),
        };

        const total_len = @sizeOf(EntryHeader) + key.len + value.len;
        const aligned_len = std.mem.alignForward(usize, total_len, BLOCK_SIZE);
        const buf = try store.allocator.alignedAlloc(u8, BLOCK_SIZE, aligned_len);

        std.mem.copyForwards(u8, buf[0..8], std.mem.asBytes(&header));
        std.mem.copyForwards(u8, buf[8..][0..key.len], key);
        std.mem.copyForwards(u8, buf[8 + key.len ..][0..value.len], value);

        _ = store.pending_ops.fetchAdd(1, .acquire);

        const offset = @atomicRmw(u64, &store.file_size, .Add, aligned_len, .acquire);

        var sqe = try store.ring.get_sqe();
        sqe.prep_write(store.fd, buf, offset);
        sqe.user_data = @intFromPtr(buf.ptr);

        log.debug("Submitting write for key '{s}' at offset {d} (size: {d} bytes)", .{ key, offset, aligned_len });

        store.completion_mutex.lock();

        // Copy key/value for later use by the completion handler.
        const key_copy = try store.allocator.dupe(u8, key);
        const value_copy = try store.allocator.dupe(u8, value);

        try store.pending_buffers.put(store.allocator, sqe.user_data, .{
            .buf = buf,
            .offset = offset,
            .key = key_copy,
            .value = value_copy,
            .result = result,
        });

        _ = try store.ring.submit_and_wait(1);
        log.debug("Write submitted for key '{s}' (user_data: {x})", .{ key, sqe.user_data });

        try store.processCompletions();
        result.completion.wait();
        if (result.err) |err| return err;
        store.completion_mutex.unlock();
    }

    pub fn get(store: *Phage, key: []const u8, allocator: Allocator) ![]u8 {
        log.debug("GET request for key '{s}'", .{key});

        store.index_mutex.lock();
        const entry = store.index.get(key) orelse {
            store.index_mutex.unlock();
            return error.NotFound;
        };
        store.index_mutex.unlock();

        log.debug("Found key '{s}' at offset {d} (len: {d})", .{ key, entry.offset, entry.len });

        const buf = try allocator.alignedAlloc(u8, BLOCK_SIZE, entry.len);
        defer allocator.free(buf);

        _ = store.pending_ops.fetchAdd(1, .acquire);

        var sqe = try store.ring.get_sqe();
        sqe.prep_read(store.fd, buf, entry.offset);
        sqe.user_data = @intFromPtr(buf.ptr);

        _ = try store.ring.submit_and_wait(1);

        log.debug("Read submitted for key '{s}' (user_data: {x})", .{ key, sqe.user_data });

        try store.processCompletions();

        const header = std.mem.bytesToValue(EntryHeader, buf[0..8]);
        const value_start = 8 + header.key_len;

        log.debug("Read completed for key '{s}'", .{key});
        return try allocator.dupe(u8, buf[value_start..][0..header.val_len]);
    }

    inline fn processCompletions(store: *Phage) !void {
        var cqes: [MAX_IN_FLIGHT]linux.io_uring_cqe = undefined;
        var total_processed: usize = 0;

        while (true) {
            // Use non-blocking peek first
            const count = store.ring.cq_ready();
            if (count == 0) break;

            // Now copy the CQEs
            const actual = store.ring.copy_cqes(&cqes, 0) catch |err| {
                if (err == error.SignalInterrupt) {
                    log.debug("Interrupted, retrying...", .{});
                    continue;
                }
                return err;
            };
            total_processed += actual;

            for (cqes[0..actual]) |cqe| {
                defer _ = store.pending_ops.fetchSub(1, .release);

                if (cqe.res < 0) {
                    const errno = linux.E.init(@intCast(-cqe.res));
                    log.err("IO error (user_data: {x}): {d}", .{ cqe.user_data, errno });
                    return error.IOError;
                }

                if (store.pending_buffers.fetchRemove(cqe.user_data)) |entry| {
                    log.debug("Completing write {x} ({d} bytes)", .{ cqe.user_data, cqe.res });

                    // Update the index with the key.
                    store.index_mutex.lock();
                    defer store.index_mutex.unlock();
                    try store.index.put(store.allocator, entry.value.key, .{
                        .offset = entry.value.offset,
                        .len = @intCast(entry.value.buf.len),
                        .key_allocated = true,
                    });

                    // Update file size.
                    store.file_size = entry.value.offset + entry.value.buf.len;

                    // Free only the duplicated value and buffer;
                    // do NOT free entry.value.key because it's now stored in the index.
                    store.allocator.free(entry.value.value);
                    store.allocator.free(entry.value.buf);

                    entry.value.result.completion.set();
                }
            }
        }

        if (total_processed > 0) {
            log.debug("Processed {d} completions", .{total_processed});
        }
    }

    pub fn deinit(store: *Phage) void {
        log.info("Shutting down store...", .{});

        while (store.pending_ops.load(.acquire) > 0) {
            store.processCompletions() catch {};
        }

        var it = store.pending_buffers.iterator();
        while (it.next()) |entry| {
            log.debug("Cleaning up pending buffer {x}", .{@intFromPtr(entry.value_ptr.buf.ptr)});
            store.allocator.free(entry.value_ptr.buf);
        }
        store.pending_buffers.deinit(store.allocator);

        // Free keys in the index that were allocated via dupe.
        var index_it = store.index.iterator();
        while (index_it.next()) |entry| {
            if (entry.value_ptr.key_allocated) {
                store.allocator.free(entry.key_ptr.*);
            }
        }
        store.index.deinit(store.allocator);

        store.ring.deinit();
        std.posix.close(store.fd);

        log.info("Resources released", .{});

        store.allocator.destroy(store);
    }
};

test "basic operations" {
    // Initialize logging
    log.info("\n\n=== Starting Phage Tests ===\n", .{});

    const allocator = std.testing.allocator;
    const test_file = "phage_test.db";
    defer std.posix.unlink(test_file) catch {};

    // Force clean start
    std.posix.unlink(test_file) catch {};

    log.info("Test phase 1: Initialization", .{});
    var store = blk: {
        const s = Phage.init(allocator, test_file) catch |err| {
            std.log.err("INIT FAILED: {s}", .{@errorName(err)});
            return err;
        };
        break :blk s;
    };
    defer {
        log.info("Test phase 4: Cleanup", .{});
        store.deinit();
    }

    log.info("Test phase 2: Writes", .{});
    try store.put("key1", "value1");

    log.info("Test phase 3: Verification", .{});
    const val = try store.get("key1", allocator);
    defer allocator.free(val);
    try std.testing.expectEqualStrings("value1", val);

    log.info("=== All Tests Passed ===", .{});
}
