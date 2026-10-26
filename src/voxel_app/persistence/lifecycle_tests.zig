//! Deterministic gates exercise the real encoder, queue, WAL, and sync adapter.
const std = @import("std");
const format = @import("format.zig");
const storage = @import("storage.zig");
const adapter = @import("io.zig");
const coordinator = @import("coordinator.zig");
const Mode = enum { write_stall, sync_stall, write_failure, queued_write_failure, sync_failure, footer_cancel, before_cancel, priority, tiny_output, tiny_working, manifest_limit };
const Gate = struct {
    io: std.Io,
    operation: adapter.Operation,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    open: bool = false,
    entered: bool = false,
    released: usize = 0,
    release_counts: [128]u8 = @splat(0),
    release_order: [128]u32 = @splat(0),
    skip_writes: usize = 0,
    writes: usize = 0,
    hold_first_release: bool = false,
    encoded: bool = false,
    committed: bool = false,
    failure: ?anyerror = null,
    fn hook(context: ?*anyopaque, op: adapter.Operation) void {
        const self: *Gate = @ptrCast(@alignCast(context.?));
        if (op != self.operation) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (op == .write) {
            self.writes += 1;
            if (self.writes <= self.skip_writes) return;
        }
        if (self.open) return;
        self.entered = true;
        self.changed.broadcast(self.io);
        while (!self.open) self.changed.waitUncancelable(self.io, &self.mutex);
    }
    fn notify(context: *anyopaque, event: coordinator.Event) void {
        const self: *Gate = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (event) {
            .released => |released_event| {
                self.release_counts[released_event.id] += 1;
                self.release_order[self.released] = released_event.id;
                self.released += 1;
                if (self.hold_first_release and self.released == 1) {
                    self.entered = true;
                    self.changed.broadcast(self.io);
                    while (!self.open) self.changed.waitUncancelable(self.io, &self.mutex);
                }
            },
            .encoded => self.encoded = true,
            .committed => self.committed = true,
            .finished => |finish| self.failure = finish.failure,
            else => {},
        }
        self.changed.broadcast(self.io);
    }
    fn release(self: *Gate) void {
        self.mutex.lockUncancelable(self.io);
        self.open = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
};
fn scenario(mode: Mode) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/persistence-lifecycle-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 8, 8, 8 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    var store = try storage.Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    defer store.deinit();
    // Establish the segment before gates so full_sync means the transaction commit barrier.
    try store.rotate();
    var gate: Gate = .{
        .io = io,
        .operation = if (mode == .write_stall or mode == .write_failure or mode == .queued_write_failure or mode == .footer_cancel or mode == .before_cancel) .write else .full_sync,
        // Header, global, empty players, chunk; the fifth adapter write is footer.
        .skip_writes = if (mode == .footer_cancel) 4 else if (mode == .queued_write_failure) 3 else 0,
    };
    const stalls = mode == .queued_write_failure or mode == .write_stall or mode == .sync_stall or mode == .footer_cancel or mode == .before_cancel;
    var faults: adapter.Faults = .{ .operation = gate.operation, .enabled = mode == .write_failure or mode == .sync_failure or mode == .queued_write_failure, .after = if (mode == .queued_write_failure) 3 else 0, .hook = if (stalls) Gate.hook else null, .context = &gate };
    store.setFaults(&faults);
    defer store.setFaults(null);
    var blocks: [32768]u8 = undefined;
    for (&blocks, 0..) |*cell, i| cell.* = @intCast(i % 2 + 1);
    var first_blocks = blocks;
    const count: usize = if (mode == .priority) 80 else if (mode == .write_stall or mode == .queued_write_failure) 64 else 1;
    gate.hold_first_release = mode == .priority;
    const sources = try a.alloc(coordinator.Source, count);
    for (sources, 0..) |*source, i| source.* = .{ .id = @intCast(i), .revision = 1, .epoch = 1, .is_unreachable = false, .blocks = if (i == 0) &first_blocks else &blocks, .roads = &.{}, .constructed = &.{}, .events = &.{} };
    const players = try a.alloc(u8, 0);
    const job = try a.create(coordinator.Job);
    var store_mutex: std.Io.Mutex = .init;
    job.* = .{ .allocator = a, .io = io, .store = &store, .store_mutex = &store_mutex, .limits = .{
        .output_bytes = if (mode == .tiny_output) 58 + format.cell_count - 1 else format.max_chunk_record_bytes,
        .working_bytes = if (mode == .tiny_working) format.max_chunk_record_bytes else 64 * 1024 * 1024,
        .manifest_entries = if (mode == .manifest_limit) 0 else 65536,
    }, .notify = .{ .context = &gate, .send = Gate.notify }, .epoch = 1, .sequence = 1, .tick = 60, .final = false, .sources = sources, .players = players, .player_count = 0 };
    // Sources remain borrowed at their exact original addresses: admission
    // checks must fail before allocation, sort, worker start, or release events.
    try std.testing.expect(job.sources[0].blocks.? == &first_blocks);
    if (mode == .tiny_output or mode == .tiny_working or mode == .manifest_limit) {
        defer a.destroy(job);
        defer a.free(players);
        defer a.free(sources);
        if (mode == .tiny_output) try std.testing.expectError(error.OutputCapacityTooSmall, job.start());
        if (mode == .tiny_working) try std.testing.expectError(error.WorkingCapacityExceeded, job.start());
        if (mode == .manifest_limit) try std.testing.expectError(error.ManifestCapacityExceeded, job.start());
        try std.testing.expectEqual(@as(usize, 0), gate.released);
        try std.testing.expect(!gate.encoded and !gate.committed);
        try std.testing.expect(!job.start_ready);
        try std.testing.expectEqual(@as(usize, 0), job.released.len);
        try std.testing.expectEqual(@as(usize, 0), job.priority.len);
        try std.testing.expectEqual(@as(usize, 0), job.output.capacity);
        try std.testing.expectEqual(@as(u64, 0), store.sequence);
        try std.testing.expectEqual(storage.Phase.ready, store.phase);
        return;
    }
    try job.start();
    defer job.deinit();
    if (mode == .priority) {
        gate.mutex.lockUncancelable(io);
        while (!gate.entered) gate.changed.waitUncancelable(io, &gate.mutex);
        gate.mutex.unlock(io);
        // Encoder is inside release(0); every other source still points at
        // live storage. Prioritize48 distinct IDs, beyond the old27-ID limit.
        var priorities: [48]u32 = undefined;
        for (&priorities, 0..) |*id, i| id.* = @intCast(79 - i);
        job.prioritize(&priorities);
        // Source0 is released and may now mutate; every held source still
        // borrows the separate immutable blocks array at its original address.
        try std.testing.expect(job.sources[79].blocks.? == &blocks);
        @memset(&first_blocks, 1);
        gate.release();
        job.writer.await(io);
        job.encoder.await(io);
        try std.testing.expect(gate.failure == null);
        try std.testing.expect(gate.committed);
        try std.testing.expectEqual(@as(usize, 80), gate.released);
        try std.testing.expectEqual(@as(u32, 0), gate.release_order[0]);
        for (gate.release_order[1..49], 32..) |id, expected| try std.testing.expectEqual(@as(u32, @intCast(expected)), id);
        for (gate.release_order[49..80], 1..) |id, expected| try std.testing.expectEqual(@as(u32, @intCast(expected)), id);
        for (gate.release_counts[0..count]) |released_count| try std.testing.expectEqual(@as(u8, 1), released_count);
        try std.testing.expect(job.peak_bytes <= job.limits.output_bytes);
        try std.testing.expectEqual(@as(usize, 0), job.output_bytes);
        try std.testing.expectEqual(@as(u64, 1), store.sequence);
        try store.compact();
        const first_bytes = (try store.readChunk(a, 0)).?;
        defer a.free(first_bytes);
        var first = try format.decodeChunk(a, uuid, first_bytes, store.dimensions);
        defer first.deinit(a);
        try std.testing.expectEqual(@as(u8, 2), first.blocks[1]);
        const last_bytes = (try store.readChunk(a, 79)).?;
        defer a.free(last_bytes);
        var last = try format.decodeChunk(a, uuid, last_bytes, store.dimensions);
        defer last.deinit(a);
        try std.testing.expectEqualSlices(u8, &blocks, last.blocks);
        return;
    }
    if (stalls) {
        gate.mutex.lockUncancelable(io);
        while (!gate.entered) gate.changed.waitUncancelable(io, &gate.mutex);
        if (mode == .write_stall or mode == .queued_write_failure) {
            // 36 raw records fit; reservation blocks source 37 before encoding.
            while (gate.released < 36) gate.changed.waitUncancelable(io, &gate.mutex);
        } else if (mode != .before_cancel) while (!gate.encoded) gate.changed.waitUncancelable(io, &gate.mutex);
        const premature_ack = gate.committed;
        gate.mutex.unlock(io);
        if (mode == .queued_write_failure) {
            job.mutex.lockUncancelable(io);
            const consumed = job.output_head;
            const queued = job.output.items.len - consumed;
            var queued_bytes: usize = 0;
            for (job.output.items[consumed..]) |bytes| queued_bytes += bytes.len;
            const charged = job.output_bytes;
            job.mutex.unlock(io);
            try std.testing.expectEqual(@as(usize, 1), consumed);
            try std.testing.expect(queued > 0);
            // The stalled writer's popped record is still charged to the cap.
            try std.testing.expect(charged > queued_bytes);
        }
        if (mode == .footer_cancel) {
            try std.testing.expect(job.commit_started);
            const started = coordinator.now(io);
            job.cancel();
            // This call executes before opening the disk gate: a lock held over
            // footer I/O would deadlock here instead of completing cancellation.
            try std.testing.expect(coordinator.now(io) - started < 100 * std.time.ns_per_ms);
            try std.testing.expect(!job.canceled.load(.acquire));
        }
        if (mode == .write_stall or mode == .before_cancel) {
            job.cancel();
            // Writer is still blocked: cancellation must hand off every source independently.
            job.encoder.await(io);
            try std.testing.expect(gate.encoded);
            try std.testing.expectEqual(count, gate.released);
        }
        gate.release();
        job.writer.await(io);
        job.encoder.await(io);
        try std.testing.expect(!premature_ack);
        try std.testing.expect(job.peak_bytes <= format.max_chunk_record_bytes);
        if (mode == .write_stall or mode == .before_cancel or mode == .queued_write_failure) {
            try std.testing.expect(!job.commit_started);
            try std.testing.expect(gate.failure != null);
            try std.testing.expectEqual(@as(u64, 0), store.sequence);
        } else {
            try std.testing.expect(gate.failure == null);
            try std.testing.expect(gate.committed);
            try std.testing.expectEqual(@as(u64, 1), store.sequence);
        }
    } else {
        job.writer.await(io);
        job.encoder.await(io);
        try std.testing.expect(gate.failure != null);
        try std.testing.expect(gate.encoded);
        try std.testing.expect(!gate.committed);
        try std.testing.expectEqual(@as(u64, 0), store.sequence);
        try std.testing.expectEqual(storage.Phase.ready, store.phase);
    }
    if (mode == .queued_write_failure) {
        // deinit must free these queued records, but never the writer-owned
        // record that the failed write already released.
        try std.testing.expect(job.output_head < job.output.items.len);
    }
    for (gate.release_counts[0..count]) |released_count| try std.testing.expectEqual(@as(u8, 1), released_count);
    if (mode == .before_cancel) try std.testing.expect(gate.writes < 5);
}
test "cancellation releases all sources while real writer remains stalled and queue bounded" {
    try scenario(.write_stall);
}
test "source release precedes independent durable sync gate and acknowledgement" {
    try scenario(.sync_stall);
}
test "actual write and durability failures release sources without acknowledgement" {
    try scenario(.write_failure);
    try scenario(.sync_failure);
}

test "footer transition wins cancellation without holding cancellation lock over IO" {
    try scenario(.footer_cancel);
}
test "cancellation before footer transition prevents commit footer" {
    try scenario(.before_cancel);
}

test "all48 prioritized sources beyond27 encode first with exactly one release" {
    try scenario(.priority);
}
test "tiny output working and manifest admission fail before workers borrow sources" {
    try scenario(.tiny_output);
    try scenario(.tiny_working);
    try scenario(.manifest_limit);
}

test "failed queued write frees only unconsumed output and retains writer byte charge" {
    try scenario(.queued_write_failure);
}
