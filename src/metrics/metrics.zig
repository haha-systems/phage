// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
pub const metrics = @This();

pub const Snapshot = struct {
    reads: u64,
    writes: u64,
    deletes: u64,
    read_errors: u64,
    write_errors: u64,
    delete_errors: u64,
    total_read_latency_ns: u64,
    total_write_latency_ns: u64,
    total_delete_latency_ns: u64,
};

pub const Metrics = struct {
    reads: std.atomic.Value(u64),
    writes: std.atomic.Value(u64),
    deletes: std.atomic.Value(u64),
    read_errors: std.atomic.Value(u64),
    write_errors: std.atomic.Value(u64),
    delete_errors: std.atomic.Value(u64),
    read_latency: std.atomic.Value(u64),
    write_latency: std.atomic.Value(u64),
    delete_latency: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .reads = std.atomic.Value(u64).init(0),
            .writes = std.atomic.Value(u64).init(0),
            .deletes = std.atomic.Value(u64).init(0),
            .read_errors = std.atomic.Value(u64).init(0),
            .write_errors = std.atomic.Value(u64).init(0),
            .delete_errors = std.atomic.Value(u64).init(0),
            .read_latency = std.atomic.Value(u64).init(0),
            .write_latency = std.atomic.Value(u64).init(0),
            .delete_latency = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordRead(self: *Metrics, latency_ns: u64) void {
        self.recordReads(1, latency_ns);
    }

    pub fn recordReads(self: *Metrics, count: u64, latency_ns: u64) void {
        _ = self.reads.fetchAdd(count, .monotonic);
        _ = self.read_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordReadError(self: *Metrics, latency_ns: u64) void {
        _ = self.read_errors.fetchAdd(1, .monotonic);
        _ = self.read_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordWrite(self: *Metrics, latency_ns: u64) void {
        self.recordWrites(1, latency_ns);
    }

    pub fn recordWrites(self: *Metrics, count: u64, latency_ns: u64) void {
        _ = self.writes.fetchAdd(count, .monotonic);
        _ = self.write_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordWriteError(self: *Metrics, latency_ns: u64) void {
        _ = self.write_errors.fetchAdd(1, .monotonic);
        _ = self.write_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordDelete(self: *Metrics, latency_ns: u64) void {
        _ = self.deletes.fetchAdd(1, .monotonic);
        _ = self.delete_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn recordDeleteError(self: *Metrics, latency_ns: u64) void {
        _ = self.delete_errors.fetchAdd(1, .monotonic);
        _ = self.delete_latency.fetchAdd(latency_ns, .monotonic);
    }

    pub fn snapshot(self: *const Metrics) Snapshot {
        return .{
            .reads = self.reads.load(.monotonic),
            .writes = self.writes.load(.monotonic),
            .deletes = self.deletes.load(.monotonic),
            .read_errors = self.read_errors.load(.monotonic),
            .write_errors = self.write_errors.load(.monotonic),
            .delete_errors = self.delete_errors.load(.monotonic),
            .total_read_latency_ns = self.read_latency.load(.monotonic),
            .total_write_latency_ns = self.write_latency.load(.monotonic),
            .total_delete_latency_ns = self.delete_latency.load(.monotonic),
        };
    }
};
