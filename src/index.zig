// src/index.zig

const std = @import("std");
const StringContext = @import("string_context.zig").StringContext;
const prefetch = @import("root.zig").Phage.prefetch;
const INDEX_SHARDS = 16;
const HASH_SEED: u64 = 0xdeadbeef;

pub const IndexEntry = packed struct {
    offset: usize, // Offset of the value in the file
    len: usize, // Length of the entry, key, and value
    key_len: usize, // Length of the key
    val_len: usize, // Length of the value

    pub fn toHeader(self: *IndexEntry) EntryHeader {
        return EntryHeader{
            .key_len = self.key_len,
            .val_len = self.val_len,
        };
    }

    pub fn fromHeader(self: *IndexEntry, header: EntryHeader) void {
        self.key_len = header.key_len;
        self.val_len = header.val_len;
    }
};

pub const EntryHeader = packed struct {
    key_len: u32,
    val_len: u32,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("invalid header size");
    }
};

pub const IndexManager = struct {
    shards: []IndexShard,

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
            var it = self.map.iterator();
            while (it.next()) |entry| {
                // Free both key and value
                allocator.free(entry.key_ptr.*);
            }
            self.map.clearAndFree();
        }
    };

    pub fn init(allocator: std.mem.Allocator) !IndexManager {
        const shards = try allocator.alloc(IndexShard, INDEX_SHARDS);
        for (shards) |*shard| {
            shard.* = IndexShard.init(allocator);
        }
        return .{ .shards = shards };
    }

    pub fn deinit(self: IndexManager, allocator: std.mem.Allocator) void {
        for (self.shards) |*shard| {
            shard.deinit(allocator);
        }
        allocator.free(self.shards);
    }

    pub fn getShard(self: *IndexManager, key: []const u8) *IndexShard {
        const hash = std.hash.Wyhash.hash(HASH_SEED, key);
        const id = hash & (self.shards.len - 1);
        return &self.shards[id];
    }

    pub fn count(self: *IndexManager) usize {
        var total: usize = 0;
        for (self.shards) |shard| {
            total += shard.map.count();
        }
        return total;
    }

    pub fn put(self: *IndexManager, allocator: std.mem.Allocator, key: []const u8, entry: IndexEntry) !void {
        const shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();

        const key_copy = try allocator.dupe(u8, key); // Duplicate key for hash map
        errdefer allocator.free(key_copy); // Free the duplicated key if not used

        const gop = try shard.map.getOrPut(key_copy);

        if (gop.found_existing) {
            // Free old key and value
            allocator.free(gop.key_ptr.*);

            // Update with new copies
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = .{
                .offset = entry.offset,
                .len = @sizeOf(EntryHeader) + entry.key_len + entry.val_len,
                .val_len = entry.val_len,
                .key_len = entry.key_len,
            };
        } else {
            gop.value_ptr.* = .{
                .offset = entry.offset,
                .len = @sizeOf(EntryHeader) + entry.key_len + entry.val_len,
                .val_len = entry.val_len,
                .key_len = entry.key_len,
            };
        }
    }

    pub fn get(self: *IndexManager, key: []const u8) ?IndexEntry {
        const shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();
        return shard.map.get(key);
    }
};

test "init" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    try std.testing.expectEqual(INDEX_SHARDS, index.shards.len);
}

test "count" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    try std.testing.expectEqual(0, index.count());
}

test "getShard" {
    const allocator = std.testing.allocator;
    var index = try IndexManager.init(allocator);
    defer index.deinit(allocator);

    const key = "test";
    const hash = std.hash.Wyhash.hash(HASH_SEED, key);
    const id = hash & (index.shards.len - 1);
    const shard = &index.shards[id];

    try std.testing.expectEqual(INDEX_SHARDS, index.shards.len);
    try std.testing.expectEqual(shard, &index.shards[id]);
}

test "put and get entry into index" {
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

test "put and get entry with different keys" {
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

test "put and get entry with same key" {
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
