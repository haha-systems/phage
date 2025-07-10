// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");

pub const io = @This();
pub const wal = @import("wal.zig");
pub const s2s = @import("s2s.zig");

/// IO operations for the Phage server using Linux io_uring.
pub const IO = struct {
    id: u64,
    buffer: []u8,
    offset: u64,
    key: []const u8,
    value: []const u8,
    start_time: i128,
    is_write: bool,
    len: usize,

    pub fn readFromFile(
        pending_ops: *std.atomic.Value(u32),
        fd: std.posix.fd_t,
        ring: *linux.IoUring,
        buf: *const []u8,
        offset: usize,
    ) !usize {
        var sqe = try ring.get_sqe();
        sqe.prep_read(
            fd,
            buf.*,
            offset,
        );
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try ring.submit();
        const pending = pending_ops.fetchAdd(1, .monotonic);
        return submitted + pending;
    }

    pub fn writeToFile(
        pending_ops: *std.atomic.Value(u32),
        fd: std.posix.fd_t,
        ring: *linux.IoUring,
        buf: *const []u8,
        offset: usize,
    ) !usize {
        var sqe = try ring.get_sqe();
        sqe.prep_write(
            fd,
            buf.*,
            offset,
        );
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try ring.submit();
        const pending = pending_ops.fetchAdd(submitted, .monotonic);
        return submitted + pending;
    }

    /// Prefetches data from the given pointer to the L1 cache.
    /// This is a no-op on architectures that do not support prefetching.
    pub inline fn prefetch(ptr: anytype, is_write: bool) void {
        // Take address of the pointer directly, which works for any type
        const addr = @intFromPtr(&ptr);

        switch (builtin.cpu.arch) {
            .x86_64, .x86 => {
                if (is_write) {
                    // PREFETCHW for write operations (supported on some x86 CPUs)
                    asm volatile ("prefetchw (%[addr])"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                } else {
                    // PREFETCHT0 for read operations (L1 cache)
                    asm volatile ("prefetcht0 (%[addr])"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                }
            },
            .aarch64, .arm => {
                if (is_write) {
                    // PSTL1KEEP for write operations (prestore to L1)
                    asm volatile ("prfm pstl1keep, [%[addr]]"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                } else {
                    // PLDL1KEEP for read operations (preload to L1)
                    asm volatile ("prfm pldl1keep, [%[addr]]"
                        :
                        : [addr] "r" (addr),
                        : "memory"
                    );
                }
            },
            else => {
                // No explicit prefetch on other architectures
                // This function becomes a no-op
            },
        }
    }
};
