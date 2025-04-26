// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");

/// AtomicStack provides a very simple mutex-protected stack structure.
pub const AtomicStack = struct {
    mutex: *std.Thread.Mutex,
    list: std.ArrayList([]u8),
};
