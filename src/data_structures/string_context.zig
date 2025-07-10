// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");

/// A context for hashing and comparing strings.
/// This is used by the `IndexManager` to manage keys in a hash map.
pub const StringContext = struct {
    hash_seed: u64 = 0xdeadbeef,

    pub fn hash(self: @This(), s: []const u8) u64 {
        return std.hash.Wyhash.hash(self.hash_seed, s);
    }

    pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, a, b);
    }
};
