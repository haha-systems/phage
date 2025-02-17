const std = @import("std");

pub const Metrics = struct {
    reads: std.atomic.Value(u64),
    writes: std.atomic.Value(u64),
    read_latency: std.atomic.Value(u64),
    write_latency: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .reads = std.atomic.Value(u64).init(0),
            .writes = std.atomic.Value(u64).init(0),
            .read_latency = std.atomic.Value(u64).init(0),
            .write_latency = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordRead(self: *Metrics, latency_ns: u64) void {
        _ = self.reads.fetchAdd(1, .monotonic);
        _ = self.read_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordWrite(self: *Metrics, latency_ns: u64) void {
        _ = self.writes.fetchAdd(1, .monotonic);
        _ = self.write_latency.fetchAdd(latency_ns, .monotonic);
    }
};
