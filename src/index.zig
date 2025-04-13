const std = @import("std");
const StringContext = @import("string_context.zig").StringContext;
const prefetch = @import("root.zig").Phage.prefetch;
const INDEX_SHARDS = 16;
const HASH_SEED: u64 = 0xdeadbeef;

pub const IndexEntry = struct {
    offset: u64,
    len: u32,
    key_allocated: bool = false,
    key: []const u8,
    value: []const u8,
};

// sharded index for better cocurrency
pub const IndexManager = struct {
    shards: []IndexShard,

    const IndexShard = struct {
        // map: std.HashMapUnmanaged([]const u8, IndexEntry, StringContext, std.hash_map.default_max_load_percentage) align(64),
        map: std.StringHashMap(IndexEntry),
        mutex: std.Thread.Mutex,

        fn init(allocator: std.mem.Allocator) IndexShard {
            return IndexShard{
                .map = std.StringHashMap(IndexEntry).init(allocator),
                .mutex = .{},
            };
        }

        fn deinit(self: *IndexShard, allocator: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.key_allocated) {
                    allocator.free(entry.key_ptr.*);
                }
            }
            self.map.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) !IndexManager {
        const shards = try allocator.alloc(IndexShard, INDEX_SHARDS);
        for (shards) |*shard| {
            shard.* = IndexShard.init(allocator);
        }
        return IndexManager{ .shards = shards };
    }

    pub fn getShard(self: *IndexManager, key: []const u8) *IndexShard {
        const hash = std.hash.Wyhash.hash(HASH_SEED, key);
        std.log.debug("Hash for key {x} (len: {}) is {x}", .{ key, key.len, hash });

        const id = hash & (self.shards.len - 1);
        const shard = &self.shards[id];

        std.log.debug("Shard for key {s} (len: {}) is {d}", .{ key, key.len, id });
        return shard;
    }

    pub fn put(self: *IndexManager, key: []const u8, entry: IndexEntry) !void {
        var shard = self.getShard(key);
        prefetch(shard, true);

        shard.mutex.lock();
        defer shard.mutex.unlock();

        const gop = try shard.map.getOrPut(key);
        if (gop.found_existing) {
            // Update existing entry
            gop.value_ptr.offset = entry.offset;
            gop.value_ptr.len = entry.len;
            std.log.debug("Updated index entry for key '{s}' at offset {} with length {}", .{ key, entry.offset, entry.len });
        } else {
            // Insert new entry
            gop.value_ptr.* = IndexEntry{
                .offset = entry.offset,
                .len = entry.len,
                .key_allocated = false, // Hashmap owns the key
                .key = gop.key_ptr.*, // Reference the hashmap's key
                .value = entry.value, // Caller manages value memory
            };
            std.log.debug("Inserted index entry for key '{s}' at offset {} with length {}", .{ key, entry.offset, entry.len });
        }
    }

    pub fn get(self: *IndexManager, key: []const u8) ?IndexEntry {
        var shard = self.getShard(key);
        prefetch(shard, false);

        shard.mutex.lock();
        defer shard.mutex.unlock();

        std.log.debug("Looking up key {s} (len: {})", .{ key, key.len });
        std.log.debug("Shard size is {}", .{shard.map.count()});

        var iter = shard.map.iterator();
        while (iter.next()) |entry| {
            const _key = entry.value_ptr.*.key;
            const _val = entry.value_ptr.*.value;
            std.log.debug("Key in shard: {s} (len: {})", .{ _key, entry.key_ptr.len });
            std.log.debug("Value in shard: {s} (len: {})", .{ _val, entry.value_ptr.len });
        }

        const entry = shard.map.getEntry(key);
        if (entry) |e| {
            const indexEntry = e.value_ptr.*;
            std.log.debug("Found index entry for key '{s}' at offset {} with length {}", .{ key, indexEntry.offset, indexEntry.len });
            return indexEntry;
        } else {
            std.log.debug("Key '{s}' not found in index", .{key});
            return null;
        }
    }

    pub fn count(self: *IndexManager) !usize {
        var total: usize = 0;

        // lock all shards
        for (self.shards) |*shard| {
            shard.mutex.lock();
        }
        defer {
            // unlock all shards
            for (self.shards) |*shard| {
                shard.mutex.unlock();
            }
        }

        for (self.shards[0..self.shards.len]) |shard| {
            total += shard.map.size;
        }

        return total;
    }

    pub fn deinit(self: *IndexManager, allocator: std.mem.Allocator) void {
        for (self.shards) |*shard| {
            shard.deinit(allocator);
        }
        allocator.free(self.shards);
    }
};
