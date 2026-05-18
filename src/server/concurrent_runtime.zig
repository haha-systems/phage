const std = @import("std");

const phage = @import("phage");
const zimq = @import("zimq");
const server_handler = @import("handler.zig");
const server_runtime = @import("runtime.zig");

const response_send_timeout_ms: c_int = 1_000;

const RuntimeError = error{
    QueueClosed,
    InvalidMultipartRequest,
};

const Request = struct {
    identity: []u8,
    bytes: []u8,

    fn deinit(self: Request, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        allocator.free(self.bytes);
    }
};

const Response = struct {
    identity: []u8,
    bytes: []u8,

    fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        allocator.free(self.bytes);
    }
};

fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},
        items: []?T,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,

        fn init(allocator: std.mem.Allocator, queue_capacity: usize) !Self {
            std.debug.assert(queue_capacity > 0);
            const items = try allocator.alloc(?T, queue_capacity);
            @memset(items, null);
            return .{ .items = items };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
            self.* = undefined;
        }

        fn capacity(self: *const Self) usize {
            return self.items.len;
        }

        fn push(self: *Self, item: T) RuntimeError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.closed and self.len == self.items.len) {
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return error.QueueClosed;

            const tail = (self.head + self.len) % self.items.len;
            self.items[tail] = item;
            self.len += 1;
            self.not_empty.signal();
        }

        fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.closed and self.len == 0) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.len == 0) return null;
            return self.popLocked();
        }

        fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0) return null;
            return self.popLocked();
        }

        fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        fn popLocked(self: *Self) T {
            const item = self.items[self.head].?;
            self.items[self.head] = null;
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
            self.not_full.signal();
            return item;
        }
    };
}

const RequestQueue = BoundedQueue(Request);
const ResponseQueue = BoundedQueue(Response);

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    store: *phage.Phage,
    store_mutex: *std.Thread.Mutex,
    requests: *RequestQueue,
    responses: *ResponseQueue,
};

pub fn run(
    allocator: std.mem.Allocator,
    store: *phage.Phage,
    ctx: *zimq.Context,
    port: u16,
    worker_count: usize,
) !void {
    std.debug.assert(worker_count > 0);
    server_runtime.resetProcessShutdownForTests();
    server_runtime.installProcessSignalHandlers();

    const queue_capacity = worker_count * 4;
    var requests = try RequestQueue.init(allocator, queue_capacity);
    defer requests.deinit(allocator);
    defer drainRequests(allocator, &requests);

    var responses = try ResponseQueue.init(allocator, queue_capacity);
    defer responses.deinit(allocator);
    defer drainResponsesForCleanup(allocator, &responses);

    var store_mutex = std.Thread.Mutex{};
    const workers = try allocator.alloc(WorkerContext, worker_count);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    for (workers, 0..) |*worker, i| {
        worker.* = .{
            .allocator = allocator,
            .store = store,
            .store_mutex = &store_mutex,
            .requests = &requests,
            .responses = &responses,
        };
        threads[i] = try std.Thread.spawn(.{}, workerLoop, .{worker});
    }
    var workers_joined = false;
    defer if (!workers_joined) {
        requests.close();
        responses.close();
        for (threads) |thread| thread.join();
    };

    const server_router: *zimq.Socket = try .init(ctx, .router);
    defer server_router.deinit();
    try server_router.set(.linger, @as(c_int, 0));
    try server_router.set(.sndtimeo, response_send_timeout_ms);

    const bind_address = try std.fmt.allocPrintSentinel(allocator, "tcp://*:{}", .{port}, 0);
    defer allocator.free(bind_address);
    try server_router.bind(bind_address);
    std.log.info("server lifecycle event=bound address={s} runtime_model=bounded-router-serialized-store workers={} queue_capacity={}", .{ bind_address, worker_count, queue_capacity });

    while (server_runtime.processShouldContinue()) {
        try drainResponsesToRouter(allocator, server_router, &responses);

        if (try recvRouterRequest(allocator, server_router)) |request| {
            if (std.mem.eql(u8, request.bytes, "__PHAGE_SHUTDOWN__")) {
                defer request.deinit(allocator);
                try sendRouterResponse(server_router, request.identity, "OK");
                break;
            }
            try requests.push(request);
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }

    requests.close();
    responses.close();
    for (threads) |thread| thread.join();
    workers_joined = true;
    try drainResponsesToRouter(allocator, server_router, &responses);
}

fn workerLoop(worker: *WorkerContext) void {
    while (worker.requests.pop()) |request| {
        const response = handleQueuedRequest(worker.allocator, worker.store, worker.store_mutex, request) catch {
            request.deinit(worker.allocator);
            worker.responses.close();
            return;
        };
        worker.responses.push(response) catch |err| {
            response.deinit(worker.allocator);
            if (err == error.QueueClosed) return;
            return;
        };
    }
}

fn handleQueuedRequest(
    allocator: std.mem.Allocator,
    store: *phage.Phage,
    store_mutex: *std.Thread.Mutex,
    request: Request,
) !Response {
    errdefer allocator.free(request.identity);
    defer allocator.free(request.bytes);

    store_mutex.lock();
    const handler_response = try server_handler.handleRequest(allocator, store, request.bytes);
    defer {
        handler_response.deinit(allocator);
        store_mutex.unlock();
    }

    const response_bytes = try allocator.dupe(u8, handler_response.bytes);
    return .{ .identity = request.identity, .bytes = response_bytes };
}

fn recvRouterRequest(allocator: std.mem.Allocator, router: *zimq.Socket) !?Request {
    var identity_msg: zimq.Message = .empty();
    defer identity_msg.deinit();
    _ = router.recvMsg(&identity_msg, .noblock) catch |err| switch (err) {
        error.WouldBlock, error.Interrupted => return null,
        else => return err,
    };
    if (!identity_msg.more()) return error.InvalidMultipartRequest;

    const identity = try allocator.dupe(u8, identity_msg.slice());
    errdefer allocator.free(identity);

    var body: ?[]u8 = null;
    while (true) {
        var frame: zimq.Message = .empty();
        defer frame.deinit();
        _ = try router.recvMsg(&frame, .{});
        if (!frame.more()) {
            body = try allocator.dupe(u8, frame.slice());
            break;
        }
    }

    return .{ .identity = identity, .bytes = body.? };
}

fn drainResponsesToRouter(allocator: std.mem.Allocator, router: *zimq.Socket, responses: *ResponseQueue) !void {
    while (responses.tryPop()) |response| {
        defer response.deinit(allocator);
        try sendRouterResponse(router, response.identity, response.bytes);
    }
}

fn sendRouterResponse(router: *zimq.Socket, identity: []const u8, bytes: []const u8) !void {
    try router.sendSlice(identity, .more);
    try router.sendSlice("", .more);
    try router.sendSlice(bytes, .{});
}

fn drainRequests(allocator: std.mem.Allocator, requests: *RequestQueue) void {
    requests.close();
    while (requests.tryPop()) |request| request.deinit(allocator);
}

fn drainResponsesForCleanup(allocator: std.mem.Allocator, responses: *ResponseQueue) void {
    responses.close();
    while (responses.tryPop()) |response| response.deinit(allocator);
}

test "bounded queue preserves FIFO order and capacity" {
    var queue = try BoundedQueue(usize).init(std.testing.allocator, 2);
    defer queue.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), queue.capacity());
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectEqual(@as(usize, 1), queue.tryPop().?);
    try queue.push(3);
    try std.testing.expectEqual(@as(usize, 2), queue.pop().?);
    try std.testing.expectEqual(@as(usize, 3), queue.pop().?);
    try std.testing.expect(queue.tryPop() == null);
}

test "bounded queue close wakes pops and rejects pushes" {
    var queue = try BoundedQueue(usize).init(std.testing.allocator, 1);
    defer queue.deinit(std.testing.allocator);

    queue.close();
    try std.testing.expect(queue.pop() == null);
    try std.testing.expectError(error.QueueClosed, queue.push(1));
}
