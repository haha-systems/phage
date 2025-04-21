const std = @import("std");

/// AtomicStack provides a very simple mutex-protected stack structure.
pub const AtomicStack = struct {
    mutex: *std.Thread.Mutex,
    list: std.ArrayList([]u8),
};
