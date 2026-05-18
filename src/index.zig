// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
const StringContext = @import("data_structures/string_context.zig").StringContext;
const IO = @import("io/io.zig").IO;

const INDEX_SHARDS = 16;
const HASH_SEED: u64 = 0xdeadbeef;

/// The entry in the in-memory index.
pub const IndexEntry = packed struct {
    // Offset of the value in the file
    offset: usize,
    // Length of the entry, key, and value
    len: usize,
    // Length of the key
    key_len: usize,
    // Length of the value
    val_len: usize,
};

/// The header for each entry in the in-memory index.
/// Any size greater than 8 bytes is invalid and will cause a comptime error.
pub const EntryHeader = packed struct {
    key_len: u32,
    val_len: u32,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("invalid header size");
    }
};

/// IndexManager is a thread-safe in-memory index manager that uses
/// sharded hash maps to store index entries in memory.
pub const IndexManager = struct {
    pub const BatchEntry = struct { key: []const u8, entry: IndexEntry };

    shards: []IndexShard,

    /// IndexShard is a thread-safe shard of the index manager.
    /// Each shard contains a mutex-protected hash map to store index entries.
    const IndexShard = struct {
        map: std.StringHashMap(IndexEntry),
        mutex: std.Thread.Mutex,

        fn init(allocator: std.mem.Allocator) IndexShard {
            return .{
                .map = std.StringHashMap(IndexEntry).init(allocator),
                .mutex = .{},
            };
        }

        fn deinit(self: *IndexShard, allocator: std.mem.Allocator) void {
            const entryCount = self.map.count();

            if (entryCount > 0) {
                var it = self.map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
            }

            self.map.clearAndFree();
        }

        fn putLocked(self: *IndexShard, allocator: std.mem.Allocator, key: []const u8, entry: IndexEntry) !void {
            const key_copy = try allocator.dupe(u8, key);
            errdefer allocator.free(key_copy);

            const gop = try self.map.getOrPut(key_copy);
            if (gop.found_existing) {
                allocator.free(gop.key_ptr.*);
                gop.key_ptr.* = key_copy;
            }
            gop.value_ptr.* = normalizeEntry(entry);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !IndexManager {
        const shards = try allocator.alloc(IndexShard, INDEX_SHARDS);
        for (shards) |*shard| {
            shard.* = IndexShard.init(allocator);
        }
        return .{ .shards = shards };
    }

    pub fn deinit(self: *IndexManager, allocator: std.mem.Allocator) void {
        for (self.shards) |*shard| {
            shard.deinit(allocator);
        }
        allocator.free(self.shards);
    }

    fn shardIndex(self: *IndexManager, key: []const u8) usize {
        const hash = std.hash.Wyhash.hash(HASH_SEED, key);
        return hash & (self.shards.len - 1);
    }

    /// Get the shard for a given key.
    pub fn getShard(self: *IndexManager, key: []const u8) *IndexShard {
        return &self.shards[self.shardIndex(key)];
    }

    /// Count the total number of entries in all shards.
    ///
    /// **Warning**: while this function requests the underlying hash map's
    /// count, it could be slow for large indexes.
    pub fn count(self: *IndexManager) usize {
        var total: usize = 0;
        for (self.shards) |shard| {
            total += shard.map.count();
        }
        return total;
    }

    fn normalizeEntry(entry: IndexEntry) IndexEntry {
        return .{
            .offset = entry.offset,
            .len = @sizeOf(EntryHeader) + entry.key_len + entry.val_len,
            .val_len = entry.val_len,
            .key_len = entry.key_len,
        };
    }

    /// Puts an entry into the index.
    /// If the key already exists, it will be replaced.
    pub fn put(self: *IndexManager, allocator: std.mem.Allocator, key: []const u8, entry: IndexEntry) !void {
        const shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();

        try shard.putLocked(allocator, key, entry);
    }

    /// Puts a batch of entries into the index, grouping by shard so each
    /// affected shard is locked at most once for the batch.
    /// Duplicate keys are applied in input order, so the last entry wins.
    pub fn putBatch(self: *IndexManager, allocator: std.mem.Allocator, entries: []const BatchEntry) !void {
        if (entries.len == 0) return;

        for (self.shards, 0..) |*shard, shard_id| {
            var has_entries = false;
            for (entries) |batch_entry| {
                if (self.shardIndex(batch_entry.key) == shard_id) {
                    has_entries = true;
                    break;
                }
            }
            if (!has_entries) continue;

            shard.mutex.lock();
            defer shard.mutex.unlock();

            for (entries) |batch_entry| {
                if (self.shardIndex(batch_entry.key) != shard_id) continue;
                try shard.putLocked(allocator, batch_entry.key, batch_entry.entry);
            }
        }
    }

    /// Gets an entry from the index.
    /// Returns null if the key does not exist.
    pub fn get(self: *IndexManager, key: []const u8) ?IndexEntry {
        const shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();
        return if (shard.map.contains(key)) shard.map.get(key) else null;
    }

    /// Deletes an entry from the index.
    /// Returns true if the entry was deleted, false if it did not exist.
    pub fn delete(self: *IndexManager, allocator: std.mem.Allocator, key: []const u8) !bool {
        const shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();

        // Free the key we duplicated earlier in `put`
        if (shard.map.fetchRemove(key)) |kv| {
            allocator.free(kv.key);
        } else {
            return false;
        }

        return true;
    }
};

test "index:init" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    try std.testing.expectEqual(INDEX_SHARDS, index.shards.len);
}

test "index:count" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    try std.testing.expectEqual(0, index.count());
}

test "index:getShard" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator); //

    const key = "test";
    const hash = std.hash.Wyhash.hash(HASH_SEED, key);
    const id = hash & (index.shards.len - 1);
    const shard = &index.shards[id];

    try std.testing.expectEqual(INDEX_SHARDS, index.shards.len);
    try std.testing.expectEqual(shard, &index.shards[id]);
}

test "index:put_and_get_entry" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    const entry = IndexEntry{
        .offset = 0,
        .len = @sizeOf(EntryHeader) + 4 + 4,
        .val_len = 4,
        .key_len = 4,
    };

    try index.put(allocator, "key", entry);
    const result = index.get("key") orelse unreachable;
    try std.testing.expectEqual(entry.offset, result.offset);
    try std.testing.expectEqual(entry.len, result.len);
    try std.testing.expectEqual(entry.val_len, result.val_len);
    try std.testing.expectEqual(entry.key_len, result.key_len);
}

test "index:put_and_get_entry_with_different_keys" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    const entry1 = IndexEntry{
        .offset = 0,
        .len = @sizeOf(EntryHeader) + 4 + 4,
        .key_len = 4,
        .val_len = 4,
    };
    const entry2 = IndexEntry{
        .offset = 4,
        .len = @sizeOf(EntryHeader) + 4 + 4,
        .key_len = 4,
        .val_len = 4,
    };

    try index.put(allocator, "key1", entry1);
    try index.put(allocator, "key2", entry2);

    const result1 = index.get("key1") orelse unreachable;
    const result2 = index.get("key2") orelse unreachable;

    try std.testing.expectEqual(entry1.key_len, result1.key_len);
    try std.testing.expectEqual(entry1.val_len, result1.val_len);
    try std.testing.expectEqual(entry1.offset, result1.offset);
    try std.testing.expectEqual(entry1.len, result1.len);
    try std.testing.expectEqual(entry2.key_len, result2.key_len);
    try std.testing.expectEqual(entry2.val_len, result2.val_len);
    try std.testing.expectEqual(entry2.offset, result2.offset);
    try std.testing.expectEqual(entry2.len, result2.len);
}

test "index:put_and_get_entry_with_same_key" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    const entry1 = IndexEntry{
        .offset = 0,
        .len = @sizeOf(EntryHeader) + 4 + 4,
        .key_len = 4,
        .val_len = 4,
    };
    const entry2 = IndexEntry{
        .offset = 4,
        .len = @sizeOf(EntryHeader) + 4 + 4,
        .key_len = 4,
        .val_len = 4,
    };

    try index.put(allocator, "key", entry1);
    try index.put(allocator, "key", entry2);

    const result = index.get("key") orelse unreachable;
    try std.testing.expectEqual(entry2.key_len, result.key_len);
    try std.testing.expectEqual(entry2.val_len, result.val_len);
    try std.testing.expectEqual(entry2.offset, result.offset);
    try std.testing.expectEqual(entry2.len, result.len);
}

test "index:delete" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    const key = "key1";

    const entry = IndexEntry{
        .offset = 0,
        .len = @sizeOf(EntryHeader) + 4 + 4,
        .key_len = key.len,
        .val_len = 4,
    };

    try index.put(allocator, key, entry);
    const removed = try index.delete(allocator, key);

    try std.testing.expect(removed);

    const result = index.get(key);
    try std.testing.expectEqual(null, result);
}

test "index:delete_non_existing_key" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    const key = "non_existing_key";

    const removed = try index.delete(allocator, key);

    try std.testing.expect(!removed);
}

test "index:putBatch updates multiple shards and replaces duplicate keys" {
    const allocator = std.testing.allocator;
    var manager = try IndexManager.init(allocator);
    defer manager.deinit(allocator);

    var key_buffers: [3][32]u8 = undefined;
    var keys: [3][]const u8 = undefined;
    var shard_ids: [3]usize = undefined;
    var found: usize = 0;
    var candidate: usize = 0;
    while (found < keys.len) : (candidate += 1) {
        const key = try std.fmt.bufPrint(&key_buffers[found], "batch-key-{d}", .{candidate});
        const id = std.hash.Wyhash.hash(HASH_SEED, key) & (manager.shards.len - 1);
        var seen = false;
        for (shard_ids[0..found]) |existing_id| {
            if (existing_id == id) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        keys[found] = key;
        shard_ids[found] = id;
        found += 1;
    }

    const updates = [_]IndexManager.BatchEntry{
        .{ .key = keys[0], .entry = .{ .offset = 10, .len = 0, .key_len = keys[0].len, .val_len = 4 } },
        .{ .key = keys[1], .entry = .{ .offset = 20, .len = 0, .key_len = keys[1].len, .val_len = 5 } },
        .{ .key = keys[2], .entry = .{ .offset = 30, .len = 0, .key_len = keys[2].len, .val_len = 6 } },
        .{ .key = keys[1], .entry = .{ .offset = 40, .len = 0, .key_len = keys[1].len, .val_len = 7 } },
    };

    try manager.putBatch(allocator, &updates);

    try std.testing.expectEqual(@as(usize, 3), manager.count());

    const first = manager.get(keys[0]) orelse return error.MissingFirstBatchKey;
    try std.testing.expectEqual(@as(usize, 10), first.offset);
    try std.testing.expectEqual(keys[0].len, first.key_len);
    try std.testing.expectEqual(@as(usize, 4), first.val_len);

    const second = manager.get(keys[1]) orelse return error.MissingSecondBatchKey;
    try std.testing.expectEqual(@as(usize, 40), second.offset);
    try std.testing.expectEqual(keys[1].len, second.key_len);
    try std.testing.expectEqual(@as(usize, 7), second.val_len);

    const third = manager.get(keys[2]) orelse return error.MissingThirdBatchKey;
    try std.testing.expectEqual(@as(usize, 30), third.offset);
    try std.testing.expectEqual(keys[2].len, third.key_len);
    try std.testing.expectEqual(@as(usize, 6), third.val_len);
}
