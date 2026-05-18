const std = @import("std");

const phage = @import("root.zig");
const index = @import("index.zig");
const Wal = @import("io/wal.zig").Wal;

const Phage = phage.Phage;

const compaction_test_dir = ".zig-cache/phage-tests";
const compaction_test_path = compaction_test_dir ++ "/compaction_correctness.db";
const compaction_wal_boundary_path = compaction_test_dir ++ "/compaction_wal_boundary.db";
const compaction_error_path = compaction_test_dir ++ "/compaction_error_cleanup.db";
const compaction_serialization_path = compaction_test_dir ++ "/compaction_serialization.db";

test "wal_compaction: repeated updates compact to latest readable index entries" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath(compaction_test_dir);
    cleanupPath(compaction_test_path);
    defer cleanupPath(compaction_test_path);

    var store = try Phage.init(allocator, compaction_test_path);
    defer store.deinit();

    store.compaction_threshold = 2.0;
    try store.put("alpha", "alpha-v0");
    try store.put("beta", "beta-v0");
    try store.put("gamma", "gamma-v0");

    for (1..8) |i| {
        const alpha_value = try std.fmt.allocPrint(allocator, "alpha-v{d}", .{i});
        defer allocator.free(alpha_value);
        const beta_value = try std.fmt.allocPrint(allocator, "beta-v{d}", .{i});
        defer allocator.free(beta_value);
        const gamma_value = try std.fmt.allocPrint(allocator, "gamma-v{d}", .{i});
        defer allocator.free(gamma_value);

        try store.put("alpha", alpha_value);
        try store.put("beta", beta_value);
        try store.put("gamma", gamma_value);
    }

    const waste_before = store.calculateMainFileWasteRatio();
    try std.testing.expect(waste_before > 0.5);

    const alpha_stale_offset = store.index.get("alpha").?.offset;
    const beta_stale_offset = store.index.get("beta").?.offset;
    const gamma_stale_offset = store.index.get("gamma").?.offset;

    store.compaction_threshold = 0.01;
    try store.put("alpha", "alpha-final");

    try expectIndexEntryReadsValue(&store, "alpha", "alpha-final");
    try expectIndexEntryReadsValue(&store, "beta", "beta-v7");
    try expectIndexEntryReadsValue(&store, "gamma", "gamma-v7");

    const compacted_file_size = store.file_size.load(.monotonic);
    try std.testing.expect(store.index.get("alpha").?.offset < compacted_file_size);
    try std.testing.expect(store.index.get("beta").?.offset < compacted_file_size);
    try std.testing.expect(store.index.get("gamma").?.offset < compacted_file_size);
    try std.testing.expect(
        store.index.get("alpha").?.offset != alpha_stale_offset or
            store.index.get("beta").?.offset != beta_stale_offset or
            store.index.get("gamma").?.offset != gamma_stale_offset,
    );

    const waste_after = store.calculateMainFileWasteRatio();
    try std.testing.expect(waste_after < waste_before);
}

test "wal_compaction: recovery replays WAL delete after compacted index rebuild" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath(compaction_test_dir);
    cleanupPath(compaction_wal_boundary_path);
    defer cleanupPath(compaction_wal_boundary_path);

    {
        var store = try Phage.init(allocator, compaction_wal_boundary_path);
        defer store.deinit();

        try createCompactedStore(&store, allocator);
        try expectIndexEntryReadsValue(&store, "survivor", "survivor-v5");
        try expectIndexEntryReadsValue(&store, "obsolete", "obsolete-v5");

        try appendDeleteWalEntry(&store, "obsolete");
        const wal_stat = try std.posix.fstat(store.wal_fd);
        try std.testing.expect(wal_stat.size > 0);
    }

    {
        var recovered = try Phage.init(allocator, compaction_wal_boundary_path);
        defer recovered.deinit();

        try std.testing.expectError(error.KeyNotFound, recovered.get("obsolete"));
        try expectIndexEntryReadsValue(&recovered, "survivor", "survivor-v5");

        const wal_stat = try std.posix.fstat(recovered.wal_fd);
        try std.testing.expectEqual(@as(i64, 0), wal_stat.size);
    }
}

test "wal_compaction: failed inline compaction resets flag and removes temp file" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath(compaction_test_dir);
    cleanupPath(compaction_error_path);
    defer cleanupPath(compaction_error_path);

    var store = try Phage.init(allocator, compaction_error_path);
    defer store.deinit();

    const early_key = findCompactionTestKey(.early);
    const late_key = findCompactionTestKey(.late);
    const dangling_key = findCompactionTestKey(.dangling);

    store.compaction_threshold = 2.0;
    try store.put(late_key, "late-v0");
    try store.put(early_key, "early-v0");

    try store.index.put(allocator, dangling_key, .{
        .offset = 1_000_000,
        .len = @sizeOf(index.EntryHeader) + dangling_key.len + "x".len,
        .key_len = dangling_key.len,
        .val_len = "x".len,
    });

    store.compaction_threshold = 0.0;
    try store.put("trigger", "trigger-v0");

    try std.testing.expect(!store.compaction_in_progress.load(.acquire));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(compaction_error_path ++ ".compact.tmp", .{}));
    try expectIndexEntryReadsValue(&store, late_key, "late-v0");
    try expectIndexEntryReadsValue(&store, early_key, "early-v0");
    try expectIndexEntryReadsValue(&store, "trigger", "trigger-v0");
}

test "wal_compaction: mutations share compaction serialization lock" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath(compaction_test_dir);
    cleanupPath(compaction_serialization_path);
    defer cleanupPath(compaction_serialization_path);

    var store = try Phage.init(allocator, compaction_serialization_path);
    defer store.deinit();

    store.compaction_threshold = 2.0;
    try store.put("delete-target", "delete-me");

    var put_worker = MutationWorker.init();
    var batch_worker = MutationWorker.init();
    var delete_worker = MutationWorker.init();
    const batch_pairs = [_]Phage.BatchPair{
        .{ .key = "batch-a", .value = "batch-a-v0" },
        .{ .key = "batch-b", .value = "batch-b-v0" },
    };

    store.mutation_mutex.lock();
    var put_thread = try std.Thread.spawn(.{}, runPutWhileMutationLocked, .{ &store, &put_worker });
    var batch_thread = try std.Thread.spawn(.{}, runPutBatchWhileMutationLocked, .{ &store, batch_pairs[0..], &batch_worker });
    var delete_thread = try std.Thread.spawn(.{}, runDeleteWhileMutationLocked, .{ &store, &delete_worker });

    waitForWorkerStart(&put_worker);
    waitForWorkerStart(&batch_worker);
    waitForWorkerStart(&delete_worker);
    std.Thread.sleep(20 * std.time.ns_per_ms);

    try std.testing.expect(!put_worker.done.load(.acquire));
    try std.testing.expect(!batch_worker.done.load(.acquire));
    try std.testing.expect(!delete_worker.done.load(.acquire));

    store.mutation_mutex.unlock();
    put_thread.join();
    batch_thread.join();
    delete_thread.join();

    try std.testing.expect(put_worker.done.load(.acquire));
    try std.testing.expect(batch_worker.done.load(.acquire));
    try std.testing.expect(delete_worker.done.load(.acquire));
    try std.testing.expect(!put_worker.failed.load(.acquire));
    try std.testing.expect(!batch_worker.failed.load(.acquire));
    try std.testing.expect(!delete_worker.failed.load(.acquire));

    try expectIndexEntryReadsValue(&store, "put-key", "put-v0");
    try expectIndexEntryReadsValue(&store, "batch-a", "batch-a-v0");
    try expectIndexEntryReadsValue(&store, "batch-b", "batch-b-v0");
    try std.testing.expectError(error.KeyNotFound, store.get("delete-target"));
}

const MutationWorker = struct {
    started: std.atomic.Value(bool),
    done: std.atomic.Value(bool),
    failed: std.atomic.Value(bool),

    fn init() MutationWorker {
        return .{
            .started = std.atomic.Value(bool).init(false),
            .done = std.atomic.Value(bool).init(false),
            .failed = std.atomic.Value(bool).init(false),
        };
    }
};

fn runPutWhileMutationLocked(store: *Phage, worker: *MutationWorker) void {
    worker.started.store(true, .release);
    store.put("put-key", "put-v0") catch {
        worker.failed.store(true, .release);
    };
    worker.done.store(true, .release);
}

fn runPutBatchWhileMutationLocked(store: *Phage, pairs: []const Phage.BatchPair, worker: *MutationWorker) void {
    worker.started.store(true, .release);
    store.putBatch(pairs) catch {
        worker.failed.store(true, .release);
    };
    worker.done.store(true, .release);
}

fn runDeleteWhileMutationLocked(store: *Phage, worker: *MutationWorker) void {
    worker.started.store(true, .release);
    _ = store.delete("delete-target") catch {
        worker.failed.store(true, .release);
    };
    worker.done.store(true, .release);
}

fn waitForWorkerStart(worker: *MutationWorker) void {
    while (!worker.started.load(.acquire)) {
        std.Thread.yield() catch std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

const CompactionFailureKeyRole = enum { early, late, dangling };

fn findCompactionTestKey(comptime role: CompactionFailureKeyRole) []const u8 {
    const candidates = [_][]const u8{
        "compact-key-00", "compact-key-01", "compact-key-02", "compact-key-03",
        "compact-key-04", "compact-key-05", "compact-key-06", "compact-key-07",
        "compact-key-08", "compact-key-09", "compact-key-10", "compact-key-11",
        "compact-key-12", "compact-key-13", "compact-key-14", "compact-key-15",
        "compact-key-16", "compact-key-17", "compact-key-18", "compact-key-19",
        "compact-key-20", "compact-key-21", "compact-key-22", "compact-key-23",
        "compact-key-24", "compact-key-25", "compact-key-26", "compact-key-27",
        "compact-key-28", "compact-key-29", "compact-key-30", "compact-key-31",
    };

    const target_shard: usize = switch (role) {
        .early => 0,
        .late => 15,
        .dangling => 15,
    };
    const skip_first_late = role == .dangling;
    var seen_late = false;
    for (candidates) |candidate| {
        if (compactionTestShard(candidate) != target_shard) continue;
        if (skip_first_late and !seen_late) {
            seen_late = true;
            continue;
        }
        return candidate;
    }
    @panic("compaction test key candidates must cover early and late shards");
}

fn compactionTestShard(key: []const u8) usize {
    return std.hash.Wyhash.hash(0xdeadbeef, key) & 15;
}

fn createCompactedStore(store: *Phage, allocator: std.mem.Allocator) !void {
    store.compaction_threshold = 2.0;
    try store.put("survivor", "survivor-v0");
    try store.put("obsolete", "obsolete-v0");

    for (1..6) |i| {
        const survivor_value = try std.fmt.allocPrint(allocator, "survivor-v{d}", .{i});
        defer allocator.free(survivor_value);
        const obsolete_value = try std.fmt.allocPrint(allocator, "obsolete-v{d}", .{i});
        defer allocator.free(obsolete_value);

        try store.put("survivor", survivor_value);
        try store.put("obsolete", obsolete_value);
    }

    try std.testing.expect(store.calculateMainFileWasteRatio() > 0.4);
    store.compaction_threshold = 0.01;
    try store.put("compaction-boundary-trigger", "trigger-value");
    try std.testing.expect(store.calculateMainFileWasteRatio() < 0.4);
}

fn expectIndexEntryReadsValue(store: *Phage, key: []const u8, expected_value: []const u8) !void {
    const entry = store.index.get(key) orelse return error.KeyNotFound;
    const header_size = @sizeOf(index.EntryHeader);
    const total_len = header_size + key.len + expected_value.len;
    try std.testing.expectEqual(total_len, entry.len);

    const buffer = try store.allocator.alloc(u8, entry.len);
    defer store.allocator.free(buffer);
    const bytes_read = try std.posix.pread(store.fd, buffer, entry.offset);
    try std.testing.expectEqual(entry.len, bytes_read);

    const header = std.mem.bytesToValue(index.EntryHeader, buffer[0..header_size]);
    try std.testing.expectEqual(key.len, header.key_len);
    try std.testing.expectEqual(expected_value.len, header.val_len);

    const stored_key = buffer[header_size..][0..header.key_len];
    try std.testing.expectEqualStrings(key, stored_key);

    const stored_value = buffer[header_size + header.key_len ..][0..header.val_len];
    try std.testing.expectEqualStrings(expected_value, stored_value);
}

fn appendDeleteWalEntry(store: *Phage, key: []const u8) !void {
    const header = Wal.WalEntryHeader{
        .op_type = .delete,
        .key_len = key.len,
        .val_len = 0,
        .offset = 0,
        .checksum = Wal.calculateChecksum(.delete, @intCast(key.len), 0, 0, key),
        .padding = 0,
    };

    _ = try std.posix.pwrite(store.wal_fd, std.mem.asBytes(&header), 0);
    _ = try std.posix.pwrite(store.wal_fd, key, @sizeOf(Wal.WalEntryHeader));
    try std.posix.fsync(store.wal_fd);
}

fn cleanupPath(path: []const u8) void {
    std.posix.unlink(path) catch {};

    var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path}) catch return;
    std.posix.unlink(wal_path) catch {};

    var compact_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = std.fmt.bufPrint(&compact_path_buf, "{s}.compact.tmp", .{path}) catch return;
    std.posix.unlink(compact_path) catch {};
}
