const std = @import("std");

var process_shutdown_requested = std.atomic.Value(bool).init(false);

pub const ShutdownState = struct {
    requested: std.atomic.Value(bool),

    pub fn init() ShutdownState {
        return .{ .requested = std.atomic.Value(bool).init(false) };
    }

    pub fn shouldContinue(self: *const ShutdownState) bool {
        return !self.requested.load(.acquire);
    }

    pub fn requestShutdown(self: *ShutdownState) void {
        self.requested.store(true, .release);
    }

    pub fn requestFromSignal(self: *ShutdownState, signal: u8) void {
        if (isTerminationSignal(signal)) {
            self.requestShutdown();
        }
    }
};

pub fn installProcessSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = processSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

pub fn processShouldContinue() bool {
    return !process_shutdown_requested.load(.acquire);
}

pub fn resetProcessShutdownForTests() void {
    process_shutdown_requested.store(false, .release);
}

fn processSignalHandler(signal: i32) callconv(.c) void {
    if (signal < 0 or signal > std.math.maxInt(u8)) return;
    if (isTerminationSignal(@intCast(signal))) {
        process_shutdown_requested.store(true, .release);
    }
}

fn isTerminationSignal(signal: u8) bool {
    return signal == std.posix.SIG.INT or signal == std.posix.SIG.TERM;
}

test "server shutdown state stops after common termination signals" {
    var interrupt_state = ShutdownState.init();
    try std.testing.expect(interrupt_state.shouldContinue());
    interrupt_state.requestFromSignal(std.posix.SIG.INT);
    try std.testing.expect(!interrupt_state.shouldContinue());

    var terminate_state = ShutdownState.init();
    terminate_state.requestFromSignal(std.posix.SIG.TERM);
    try std.testing.expect(!terminate_state.shouldContinue());
}

test "server shutdown state ignores non-termination signals" {
    var state = ShutdownState.init();
    state.requestFromSignal(std.posix.SIG.PIPE);
    try std.testing.expect(state.shouldContinue());
}
