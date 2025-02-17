pub const PendingIO = struct {
    id: u64,
    buffer: []u8,
    offset: u64,
    key: []const u8,
    value: []const u8,
    start_time: i128,
    is_write: bool,
};
