const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("mvzr");

pub const Trie = struct {
    root: *Node,
    allocator: Allocator,

    const Node = struct {
        children: std.StringHashMap(*Node),
        is_terminal: bool,
        key: ?[]const u8,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !*Node {
            const node = try allocator.create(Node);
            node.* = Node{
                .children = std.StringHashMap(*Node).init(allocator),
                .is_terminal = false,
                .key = null,
                .allocator = allocator,
            };
            return node;
        }

        pub fn deinit(self: *Node) void {
            var it = self.children.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.children.deinit();
        }
    };

    pub fn init(allocator: Allocator) !*Trie {
        const trie = try allocator.create(Trie);
        trie.* = Trie{
            .root = try Node.init(allocator),
            .allocator = allocator,
        };
        return trie;
    }

    pub fn deinit(self: *Trie) void {
        self.root.deinit();
        self.allocator.destroy(self.root);
        self.allocator.destroy(self);
    }

    /// Inserts a key into the trie
    pub fn insert(self: *Trie, key: []const u8) !void {
        var current = self.root;

        // Insert character by character
        for (0..key.len) |i| {
            const char_slice = key[i .. i + 1];
            const gop = try current.children.getOrPut(char_slice);

            if (!gop.found_existing) {
                gop.value_ptr.* = try Node.init(self.allocator);
            }

            current = gop.value_ptr.*;
        }

        current.is_terminal = true;
        current.key = key;
    }

    /// Searches character by character for a key in the trie
    /// Returns true if the key exists, false otherwise
    pub fn search(self: *const Trie, key: []const u8) bool {
        var current = self.root;

        for (0..key.len) |i| {
            const char_slice = key[i .. i + 1];
            current = current.children.get(char_slice) orelse return false;
        }

        return current.is_terminal;
    }

    // Finds all keys in the trie that start with the given prefix
    pub fn findKeysWithPrefix(
        self: *const Trie,
        prefix: []const u8,
        results: *std.ArrayList([]const u8),
    ) !void {
        var current = self.root;

        // Traverse the trie to find the node corresponding to the prefix
        for (0..prefix.len) |i| {
            const char_slice = prefix[i .. i + 1];
            current = current.children.get(char_slice) orelse return error.InvalidPrefix;
        }

        // Collect all keys with depth-first search
        try self.collectKeys(current, results);
    }

    // Returns all keys in the trie
    pub fn getAllKeys(self: *const Trie, results: *std.ArrayList([]const u8)) !void {
        // Collect all keys with depth-first search
        try self.collectKeys(self.root, results);
    }

    // Perform depth-first search to collect keys
    fn collectKeys(
        self: *const Trie,
        node: *const Node,
        results: *std.ArrayList([]const u8),
    ) !void {
        if (node.is_terminal) {
            const key = node.key orelse return error.InvalidKey;
            try results.append(key);
        }

        var it = node.children.iterator();
        while (it.next()) |entry| {
            try self.collectKeys(entry.value_ptr.*, results);
        }
    }

    /// Match a regular expression against all keys in the trie by first getting all keys
    /// and then using the regex pattern to filter the results.
    /// The regex pattern should be a valid regex string.
    /// The results are stored in the provided ArrayList.
    pub fn matchRegex(self: *const Trie, pattern: []const u8, results: *std.ArrayList([]const u8)) !void {
        std.log.debug("Matching regex: {s}", .{pattern});
        const compiled_regex = regex.compile(pattern) orelse return error.InvalidRegex;

        // Get all keys first
        var all_keys = std.ArrayList([]const u8).init(self.allocator);
        defer all_keys.deinit();

        try self.getAllKeys(&all_keys);

        // Filter by regex
        for (all_keys.items) |key| {
            if (compiled_regex.isMatch(key)) {
                try results.append(key);
            }
        }
    }
};

test "trie:insert_and_search" {
    const allocator = std.testing.allocator;
    const trie = try Trie.init(allocator);
    defer trie.deinit();

    try trie.insert("hello");
    try trie.insert("world");

    try std.testing.expect(trie.search("hello"));
    try std.testing.expect(!trie.search("hell"));
    try std.testing.expect(trie.search("world"));
    try std.testing.expect(!trie.search("worlds"));
}

test "trie:find_keys_with_prefix" {
    const allocator = std.testing.allocator;
    const trie = try Trie.init(allocator);
    defer trie.deinit();

    try trie.insert("hello");
    try trie.insert("hell");
    try trie.insert("worldss");

    var results = std.ArrayList([]const u8).init(allocator);
    defer results.deinit();

    try trie.findKeysWithPrefix("he", &results);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expect(std.mem.eql(u8, "hell", results.items[0]));
    try std.testing.expect(std.mem.eql(u8, "hello", results.items[1]));
    try std.testing.expect(!std.mem.eql(u8, "world", results.items[0]));
}

test "trie:match_regex" {
    const allocator = std.testing.allocator;
    const trie = try Trie.init(allocator);
    defer trie.deinit();

    try trie.insert("hello");
    try trie.insert("hell");
    try trie.insert("worlds");

    var results = std.ArrayList([]const u8).init(allocator);
    defer results.deinit();

    try trie.matchRegex("he.*", &results);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expect(std.mem.eql(u8, "hell", results.items[0]));
    try std.testing.expect(std.mem.eql(u8, "hello", results.items[1]));
}
