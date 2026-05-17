pub fn myLogFn(level: anytype, scope: anytype, comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}
