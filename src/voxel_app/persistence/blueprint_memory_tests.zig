//! Requested allocation capacity for blueprint preparation, independent of RSS.
const std = @import("std");
const blueprints = @import("blueprints.zig");
const wire = @import("format.zig");
const Allocator = std.mem.Allocator;
const mib = 1024 * 1024;
const dimensions: [3]u32 = .{ 512, 512, 8 };
const dense_size: [3]u32 = .{ 128, 128, 64 };
const dense_cells = 1_048_576;

/// Count successful allocations, including container spare capacity and both
/// buffers during allocation/copy/free growth. The backing allocator's page and
/// debug metadata are intentionally excluded.
const Meter = struct {
    backing: Allocator,
    live: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,

    fn allocator(self: *Meter) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn note(self: *Meter, before: usize, after: usize) void {
        self.live = self.live - before + after;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations += 1;
        self.note(0, len);
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, len, ra)) return false;
        self.note(memory.len, len);
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, len, ra) orelse return null;
        self.note(memory.len, len);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Meter = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ra);
        self.note(memory.len, 0);
    }
};

fn seed(state: *blueprints.State, definition_count: usize) !void {
    const a = std.testing.allocator;
    const cells = try a.alloc(u8, dense_cells);
    defer a.free(cells);
    @memset(cells, 10);
    for (0..definition_count) |index| {
        const encoded = try blueprints.encodeOps(a, &.{.{ .definition = .{
            .id = index + 1,
            .owner = 7,
            .name = "Dense",
            .size = dense_size,
            .cells = cells,
            .target_count = dense_cells,
        } }});
        defer a.free(encoded);
        var prepared = try state.prepare(encoded, dimensions, .{});
        defer prepared.deinit();
        state.apply(&prepared);
    }
    const encoded = try blueprints.encodeOps(a, &.{.{ .instance = .{ .id = 1, .definition_id = 1, .owner = 7, .origin = .{ 0, 0, 32 }, .rotation = 0 } }});
    defer a.free(encoded);
    var prepared = try state.prepare(encoded, dimensions, .{});
    defer prepared.deinit();
    state.apply(&prepared);
}

/// Build the production 13-byte wire operations without an additional million
/// element Op array. Journal storage is separate from the measured State allocator.
fn fulfillments(a: Allocator, count: usize) ![]u8 {
    const bytes = try a.alloc(u8, count * 13);
    var pos: usize = 0;
    for (0..count) |index| {
        wire.put(u8, bytes, &pos, 3);
        wire.put(u64, bytes, &pos, 1);
        wire.put(u32, bytes, &pos, @intCast(index));
    }
    return bytes;
}

test "blueprint dense maximum fulfillment measures bounded preparation capacity and replays" {
    const a = std.testing.allocator;
    var meter: Meter = .{ .backing = a };
    {
        var state = blueprints.State.init(meter.allocator());
        defer state.deinit();
        try seed(&state, 1);
        const checkpoint = try blueprints.encodeState(a, &state);
        defer a.free(checkpoint);
        const changes = try fulfillments(a, dense_cells);
        defer a.free(changes);
        try std.testing.expectEqual(@as(usize, 13_631_488), changes.len);
        const baseline = meter.live;
        const allocation_start = meter.allocations;
        meter.peak = baseline;
        {
            var prepared = try state.prepare(changes, dimensions, .{});
            defer prepared.deinit();
            const peak_extra = meter.peak - baseline;
            const prepared_extra = meter.live - baseline;
            std.debug.print("blueprint-memory dense cells={d} journal_bytes={d} baseline_bytes={d} prepare_peak_extra={d} prepared_retained_extra={d} prepare_allocations={d}\n", .{ dense_cells, changes.len, baseline, peak_extra, prepared_extra, meter.allocations - allocation_start });
            // Preparation stays below two wire copies, including deduplication and
            // operation metadata. The previous hash plus grown Op list exceeded it.
            try std.testing.expect(peak_extra <= 2 * changes.len);
            try std.testing.expect(prepared_extra <= 2 * changes.len);
            const summary: blueprints.PrepareSummary = .{ .operation_count = dense_cells, .fulfillment_count = dense_cells, .encoded_bytes = changes.len };
            try std.testing.expect(peak_extra <= try blueprints.prepareMemoryBound(summary, .{}));
            try std.testing.expectEqual(@as(u32, dense_cells), state.instances.get(1).?.remaining);
            state.apply(&prepared);
        }
        try std.testing.expectEqual(@as(u32, 0), state.instances.count());
        try std.testing.expectEqual(@as(u64, 1), state.max_instance_id);
        const expected = try blueprints.encodeState(a, &state);
        defer a.free(expected);

        // Maximum valid historical WAL progress remains replayable; a runtime
        // journal admission threshold cannot impose a new recovery restriction.
        var restored = try blueprints.decodeState(a, checkpoint, dimensions, .{});
        defer restored.deinit();
        var replayed = try restored.prepare(changes, dimensions, .{});
        defer replayed.deinit();
        restored.apply(&replayed);
        const actual = try blueprints.encodeState(a, &restored);
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    try std.testing.expectEqual(@as(usize, 0), meter.live);
}

test "blueprint sparse progress preparation does not copy a large immutable library" {
    const a = std.testing.allocator;
    var meter: Meter = .{ .backing = a };
    {
        var state = blueprints.State.init(meter.allocator());
        defer state.deinit();
        try seed(&state, 16);
        const changes = try fulfillments(a, 1);
        defer a.free(changes);
        const baseline = meter.live;
        const allocation_start = meter.allocations;
        meter.peak = baseline;
        {
            var prepared = try state.prepare(changes, dimensions, .{});
            defer prepared.deinit();
            const peak_extra = meter.peak - baseline;
            const prepared_extra = meter.live - baseline;
            std.debug.print("blueprint-memory sparse definitions=16 library_cells={d} journal_bytes={d} baseline_bytes={d} prepare_peak_extra={d} prepared_retained_extra={d} prepare_allocations={d}\n", .{ 16 * dense_cells, changes.len, baseline, peak_extra, prepared_extra, meter.allocations - allocation_start });
            try std.testing.expect(baseline >= 16 * mib);
            try std.testing.expect(peak_extra <= 512 * 1024);
            try std.testing.expect(prepared_extra <= 512 * 1024);
            const summary: blueprints.PrepareSummary = .{ .operation_count = 1, .fulfillment_count = 1, .encoded_bytes = changes.len };
            try std.testing.expect(peak_extra <= try blueprints.prepareMemoryBound(summary, .{}));
            try std.testing.expect(!state.instances.get(1).?.isFulfilled(0));
            state.apply(&prepared);
        }
        try std.testing.expect(state.instances.get(1).?.isFulfilled(0));
        try std.testing.expectEqual(@as(u32, dense_cells - 1), state.instances.get(1).?.remaining);
        try std.testing.expectEqual(baseline, meter.live);
    }
    try std.testing.expectEqual(@as(usize, 0), meter.live);
}

fn orderedFailureScenario(a: Allocator) !void {
    const fixtures = std.testing.allocator;
    const small_dimensions: [3]u32 = .{ 4, 4, 4 };
    const limits: blueprints.Limits = .{ .max_instances = 1 };
    var state = blueprints.State.init(a);
    defer state.deinit();
    const cells = [_]u8{10} ** 256;
    const initial = try blueprints.encodeOps(fixtures, &.{.{ .definition = .{ .id = 1, .owner = 7, .name = "Dense", .size = .{ 32, 8, 1 }, .cells = &cells, .target_count = cells.len } }});
    defer fixtures.free(initial);
    {
        var prepared = try state.prepare(initial, small_dimensions, limits);
        defer prepared.deinit();
        state.apply(&prepared);
    }
    const before = try blueprints.encodeState(fixtures, &state);
    defer fixtures.free(before);
    var ops: [cells.len + 3]blueprints.Op = undefined;
    ops[0] = .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 7, .origin = .{ 0, 0, 32 }, .rotation = 0 } };
    for (0..cells.len) |index| ops[index + 1] = .{ .fulfill = .{ .instance_id = 1, .cell_index = @intCast(index) } };
    ops[cells.len + 1] = .{ .instance = .{ .id = 2, .definition_id = 1, .owner = 7, .origin = .{ 0, 0, 32 }, .rotation = 0 } };
    ops[cells.len + 2] = .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } };
    const changes = try blueprints.encodeOps(fixtures, &ops);
    defer fixtures.free(changes);
    {
        var prepared = state.prepare(changes, small_dimensions, limits) catch |err| {
            const after = try blueprints.encodeState(fixtures, &state);
            defer fixtures.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            return err;
        };
        defer prepared.deinit();
        const uncommitted = try blueprints.encodeState(fixtures, &state);
        defer fixtures.free(uncommitted);
        try std.testing.expectEqualSlices(u8, before, uncommitted);
        state.apply(&prepared);
    }
    try std.testing.expect(!state.instances.contains(1));
    try std.testing.expectEqual(@as(u32, 1), state.instances.count());
    try std.testing.expectEqual(@as(u64, 2), state.max_instance_id);
    try std.testing.expect(state.instances.get(2).?.isFulfilled(0));
    try std.testing.expectEqual(@as(u32, cells.len - 1), state.instances.get(2).?.remaining);
    const checkpoint = try blueprints.encodeState(fixtures, &state);
    defer fixtures.free(checkpoint);
    var restored = try blueprints.decodeState(a, checkpoint, small_dimensions, limits);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 2), restored.max_instance_id);
    try std.testing.expect(restored.instances.get(2).?.isFulfilled(0));
    try std.testing.expectEqual(@as(u32, cells.len - 1), restored.instances.get(2).?.remaining);
}

test "blueprint adaptive progress failures preserve ordered same-batch retirement and recovery" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, orderedFailureScenario, .{});
}

const growth_lengths = [_]usize{ 2, 7, 8, 9, 17, 33, 65 };
const GrowthCase = enum { creation, mixed, progress };
const GrowthResult = struct { peak: usize, bound: usize, existing_tables_grew: bool };

fn appendGrowthCreation(ops: *std.ArrayList(blueprints.Op), first: usize, count: usize, cells: []const u8, progress: bool) !void {
    const a = std.testing.allocator;
    for (first..first + count) |index| {
        const length = growth_lengths[index % growth_lengths.len];
        const id: u64 = @intCast(index + 1);
        try ops.append(a, .{ .definition = .{ .id = id, .owner = 7, .name = "Growth", .size = .{ @intCast(length), 1, 1 }, .cells = cells[0..length], .target_count = @intCast(length) } });
        // The largest fixture has 130 disjoint sites in a 16,384-block world.
        try ops.append(a, .{ .instance = .{ .id = id, .definition_id = id, .owner = 7, .origin = .{ @intCast(index * 96), 0, 32 }, .rotation = 0 } });
        if (progress) try ops.append(a, .{ .fulfill = .{ .instance_id = id, .cell_index = 0 } });
    }
}

fn checkGrowthBound(count: usize, kind: GrowthCase) !GrowthResult {
    const a = std.testing.allocator;
    var meter: Meter = .{ .backing = a };
    var result: GrowthResult = undefined;
    {
        var state = blueprints.State.init(meter.allocator());
        defer state.deinit();
        const existing = if (kind == .creation) 0 else count;
        const created = if (kind == .progress) 0 else count;
        const final_count = existing + created;
        const limits: blueprints.Limits = .{ .max_definitions = final_count, .max_instances = final_count, .max_cells = 65 };
        const cells = [_]u8{10} ** 65;
        var ops: std.ArrayList(blueprints.Op) = .empty;
        defer ops.deinit(a);
        if (existing != 0) {
            try appendGrowthCreation(&ops, 0, existing, &cells, false);
            const initial = try blueprints.encodeOps(a, ops.items);
            defer a.free(initial);
            var prepared = try state.prepare(initial, dimensions, limits);
            defer prepared.deinit();
            state.apply(&prepared);
            ops.clearRetainingCapacity();
        }
        for (0..existing) |index| try ops.append(a, .{ .fulfill = .{ .instance_id = @intCast(index + 1), .cell_index = 0 } });
        try appendGrowthCreation(&ops, existing, created, &cells, kind == .mixed);
        const changes = try blueprints.encodeOps(a, ops.items);
        defer a.free(changes);
        var summary: blueprints.PrepareSummary = .{};
        var payload_bytes: usize = 0;
        var bitmap_bytes: usize = 0;
        for (ops.items) |op| {
            const actual_cells = switch (op) {
                .instance => |instance| growth_lengths[@as(usize, @intCast(instance.definition_id - 1)) % growth_lengths.len],
                else => 0,
            };
            try summary.addOperation(op, actual_cells);
            switch (op) {
                .definition => |definition| payload_bytes += definition.name.len + definition.cells.len,
                .instance => bitmap_bytes += (actual_cells + 7) / 8,
                else => {},
            }
        }
        try std.testing.expectEqual(changes.len, summary.encoded_bytes);
        try std.testing.expectEqual(created, summary.definition_count);
        try std.testing.expectEqual(created, summary.instance_count);
        try std.testing.expectEqual(payload_bytes, summary.definition_payload_bytes);
        try std.testing.expectEqual(bitmap_bytes, summary.new_instance_bitmap_bytes);
        const bound = try blueprints.prepareMemoryBound(summary, limits);
        const baseline = meter.live;
        const definitions_capacity = state.definitions.capacity();
        const instances_capacity = state.instances.capacity();
        meter.peak = baseline;
        {
            var prepared = try state.prepare(changes, dimensions, limits);
            defer prepared.deinit();
            const peak = meter.peak - baseline;
            errdefer std.debug.print("blueprint-memory growth case={s} count={d} peak={d} bound={d} old_definition_capacity={d} old_instance_capacity={d}\n", .{ @tagName(kind), count, peak, bound, definitions_capacity, instances_capacity });
            try std.testing.expect(peak <= bound);
            result = .{
                .peak = peak,
                .bound = bound,
                .existing_tables_grew = existing != 0 and state.definitions.capacity() > definitions_capacity and state.instances.capacity() > instances_capacity,
            };
            // Preparation can grow tables but cannot publish payloads or bits.
            try std.testing.expectEqual(@as(u32, @intCast(existing)), state.definitions.count());
            try std.testing.expectEqual(@as(u32, @intCast(existing)), state.instances.count());
            state.apply(&prepared);
        }
        try std.testing.expectEqual(@as(u32, @intCast(final_count)), state.definitions.count());
        try std.testing.expectEqual(@as(u32, @intCast(final_count)), state.instances.count());
        var sites = state.instances.valueIterator();
        while (sites.next()) |site| try std.testing.expectEqual(kind != .creation, site.isFulfilled(0));
    }
    try std.testing.expectEqual(@as(usize, 0), meter.live);
    return result;
}

test "blueprint preparation estimate covers payloads and state table growth thresholds" {
    const counts = [_]usize{ 1, 6, 7, 8, 12, 13, 16, 25, 26, 32, 65 };
    var measured: usize = 0;
    var existing_growth: usize = 0;
    var largest_peak: usize = 0;
    var largest_bound: usize = 0;
    for (counts) |count| for (std.enums.values(GrowthCase)) |kind| {
        const result = try checkGrowthBound(count, kind);
        measured += 1;
        existing_growth += @intFromBool(result.existing_tables_grew);
        largest_peak = @max(largest_peak, result.peak);
        largest_bound = @max(largest_bound, result.bound);
    };
    try std.testing.expect(existing_growth >= 6);
    std.debug.print("blueprint-memory growth cases={d} existing_table_growth_cases={d} largest_prepare_peak_extra={d} largest_bound={d}\n", .{ measured, existing_growth, largest_peak, largest_bound });
}
