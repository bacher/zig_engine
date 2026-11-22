//! Shared ownership outlives the service when a consumer still holds a package.
const std = @import("std");

pub const Budget = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limit: usize,
    used: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    rejections: std.atomic.Value(u64) = .init(0),
    references: std.atomic.Value(usize) = .init(1),
    waiting: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    notification: ?struct { context: *anyopaque, wake: *const fn (*anyopaque) void },

    pub fn create(allocator: std.mem.Allocator, io: std.Io, limit: usize, context: *anyopaque, wake: *const fn (*anyopaque) void) !*Budget {
        const self = try allocator.create(Budget);
        self.* = .{ .allocator = allocator, .io = io, .limit = limit, .notification = .{ .context = context, .wake = wake } };
        return self;
    }

    pub fn retain(self: *Budget) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Budget) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }

    pub fn detach(self: *Budget) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.notification = null;
    }

    fn notify(self: *Budget) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.notification) |value| value.wake(value.context);
    }

    pub fn reserve(self: *Budget, bytes: usize) !void {
        return self.reserveWithHeadroom(bytes, 0);
    }

    /// Leave room for the discovery metadata of the same indivisible snapshot.
    /// Only the worker reserves new bytes; consumers can release them concurrently.
    pub fn reserveWithHeadroom(self: *Budget, bytes: usize, headroom: usize) !void {
        const required = bytes +| headroom;
        var previous = self.used.load(.acquire);
        while (required <= self.limit -| previous) {
            if (self.used.cmpxchgWeak(previous, previous + bytes, .acq_rel, .acquire)) |actual| {
                previous = actual;
            } else {
                _ = self.peak.fetchMax(previous + bytes, .monotonic);
                return;
            }
        }
        _ = self.rejections.fetchAdd(1, .monotonic);
        if (required <= self.limit) {
            self.waiting.store(true, .release);
            // Pair with a release that raced the failed reservation.
            if (required <= self.limit -| self.used.load(.acquire)) self.notify();
        }
        return error.ConstructionPublicationCapacity;
    }

    pub fn releaseBytes(self: *Budget, bytes: usize) void {
        if (bytes == 0) return;
        const previous = self.used.fetchSub(bytes, .acq_rel);
        std.debug.assert(previous >= bytes);
        if (self.waiting.swap(false, .acq_rel)) self.notify();
    }
};

test "shared package cap wakes blocked publication and detaches before service retirement" {
    const Context = struct {
        count: usize = 0,
        fn wake(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
        }
    };
    var context: Context = .{};
    const budget = try Budget.create(std.testing.allocator, std.testing.io, 100, &context, Context.wake);
    defer budget.release();
    try budget.reserve(80);
    try std.testing.expectError(error.ConstructionPublicationCapacity, budget.reserve(30));
    try std.testing.expectEqual(@as(usize, 80), budget.used.load(.monotonic));
    budget.releaseBytes(20);
    try std.testing.expectEqual(@as(usize, 1), context.count);
    try budget.reserve(30);
    try std.testing.expectEqual(@as(usize, 90), budget.peak.load(.monotonic));
    try std.testing.expectError(error.ConstructionPublicationCapacity, budget.reserve(20));
    budget.detach();
    budget.releaseBytes(90);
    try std.testing.expectEqual(@as(usize, 1), context.count);
}
