//! One bounded detached compaction generation. Store preparation/publication are
//! serialized with its writer; streaming source I/O runs outside that mutex.
const std = @import("std");
const storage = @import("storage.zig");
pub const Notify = struct { context: *anyopaque, send: *const fn (*anyopaque, *Task) void };
pub const Task = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *storage.Store,
    store_mutex: *std.Io.Mutex,
    notify: Notify,
    failure: ?anyerror = null,
    catalog: ?storage.BaseCatalog = null,
    sequence: u64 = 0,
    canceled: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    pub fn start(self: *Task) !void {
        if (self.future != null) return error.CompactorAlreadyStarted;
        self.future = try self.io.concurrent(run, .{self});
    }
    pub fn cancel(self: *Task) void {
        self.canceled.store(true, .release);
    }
    pub fn await(self: *Task) void {
        if (self.future) |*future| future.await(self.io);
    }
    /// Completion handlers may take catalog by assigning null before deinit.
    pub fn deinit(self: *Task) void {
        self.await();
        if (self.catalog) |*catalog| catalog.deinit();
        self.allocator.destroy(self);
    }
    fn run(self: *Task) void {
        self.work() catch |err| {
            self.failure = err;
        };
        self.notify.send(self.notify.context, self);
    }
    fn work(self: *Task) !void {
        if (self.canceled.load(.acquire)) return error.Cancelled;
        self.store_mutex.lockUncancelable(self.io);
        var generation = self.store.prepareCompaction() catch |err| {
            self.store_mutex.unlock(self.io);
            return err;
        };
        self.store_mutex.unlock(self.io);
        defer generation.deinit();
        errdefer {
            self.store_mutex.lockUncancelable(self.io);
            self.store.abandonCompaction();
            self.store_mutex.unlock(self.io);
        }
        try generation.runWithCancellation(&self.canceled);
        self.store_mutex.lockUncancelable(self.io);
        defer self.store_mutex.unlock(self.io);
        // run's directory barrier has already made the target durable. Once that
        // succeeds, publish it even if cancellation races the completion handoff.
        try self.store.installCompaction(&generation);
        self.sequence = self.store.base_sequence;
        self.catalog = try self.store.snapshotCatalog();
    }
};
pub const CompactionTask = Task;

test "background task publishes catalog and reports pre-start cancellation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/zig-compaction-task-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const format = @import("format.zig");
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(12);
    var store = try storage.Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    defer store.deinit();
    try store.beginSnapshot(1, &global, &.{}, 0, 0);
    _ = try store.commitSnapshot();
    const Completion = struct {
        count: usize = 0,
        fn send(context: *anyopaque, _: *Task) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var completion: Completion = .{};
    var mutex: std.Io.Mutex = .init;
    const task = try a.create(Task);
    task.* = .{ .allocator = a, .io = io, .store = &store, .store_mutex = &mutex, .notify = .{ .context = &completion, .send = Completion.send } };
    try task.start();
    task.await();
    try std.testing.expect(task.failure == null);
    try std.testing.expect(task.catalog != null);
    try std.testing.expectEqual(@as(u64, 1), task.sequence);
    try std.testing.expectEqual(@as(usize, 1), completion.count);
    task.deinit();
    const canceled = try a.create(Task);
    canceled.* = .{ .allocator = a, .io = io, .store = &store, .store_mutex = &mutex, .notify = .{ .context = &completion, .send = Completion.send } };
    canceled.cancel();
    try canceled.start();
    canceled.await();
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), canceled.failure);
    try std.testing.expect(canceled.catalog == null);
    try std.testing.expect(!store.compaction_in_flight);
    canceled.deinit();
}
