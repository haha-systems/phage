const std = @import("std");

// a simple mutex-protected stack
pub const AtomicStack = struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList([]u8),
};
