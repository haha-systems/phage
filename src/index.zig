const std = @import("std");
const StringContext = @import("string_context.zig").StringContext;

const INDEX_SHARDS = 16;

pub const IndexEntry = struct {
    offset: u64,
    len: u32,
    key_allocated: bool = false,
};

// sharded index for better cocurrency
pub const IndexManager = struct {
    shards: []IndexShard,

    const IndexShard = struct {
        map: std.HashMapUnmanaged([]const u8, IndexEntry, StringContext, std.hash_map.default_max_load_percentage),
        mutex: std.Thread.Mutex,

        fn init() IndexShard {
            return .{
                .map = .{},
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
            self.map.deinit(allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !IndexManager {
        const shards = try allocator.alloc(IndexShard, INDEX_SHARDS);
        for (shards) |*shard| {
            shard.* = IndexShard.init();
        }
        return IndexManager{ .shards = shards };
    }

    pub fn getShard(self: *IndexManager, key: []const u8) *IndexShard {
        const hash = std.hash.Wyhash.hash(42, key);
        return &self.shards[hash % self.shards.len];
    }

    pub fn put(self: *IndexManager, allocator: std.mem.Allocator, key: []const u8, entry: IndexEntry) !void {
        var shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();

        const ctx = StringContext{};

        const gop = try shard.map.getOrPutAdapted(allocator, key, ctx);
        if (gop.found_existing) {
            // free existing copy of key
            if (gop.value_ptr.key_allocated) {
                allocator.free(gop.key_ptr.*);
            }

            // set new value pointer to the given entry
            gop.value_ptr.* = entry;
        } else {
            // store copy of key
            const key_copy = try allocator.dupe(u8, key);
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = entry;
            gop.value_ptr.key_allocated = true;
        }
    }

    pub fn get(self: *IndexManager, key: []const u8) ?IndexEntry {
        var shard = self.getShard(key);
        shard.mutex.lock();
        defer shard.mutex.unlock();
        return shard.map.get(key);
    }

    pub fn count(self: *IndexManager) !usize {
        var total: usize = 0;

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
