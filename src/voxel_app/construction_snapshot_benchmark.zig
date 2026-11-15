//! Focused snapshot payload benchmark. Native owned allocations, not network bytes or end-to-end throughput.
const std = @import("std");
const engine = @import("engine");
const runtime = @import("blueprint_runtime.zig");
const stream = @import("construction_stream.zig");
const blueprint = @import("blueprint.zig");
const Budget = @import("persistence/budget.zig").Budget;
const ChunkId = stream.ChunkId;

const Compact = struct {
    identity: stream.Identity,
    definition_id: u64,
    owner: u64,
    origin: runtime.Cell,
    rotation: u2,
    phase: runtime.Phase,
    revision: u64,
    fulfilled: []u8,
    transfers: []runtime.Transfer,

    fn clone(allocator: std.mem.Allocator, instance: runtime.Instance) !Compact {
        const bits = try allocator.dupe(u8, instance.fulfilled);
        errdefer allocator.free(bits);
        const count = instance.target_groups.len - instance.remaining_groups;
        const transfers = try allocator.alloc(runtime.Transfer, count);
        var slot: usize = 0;
        for (instance.target_groups) |group| if (group.transferred) {
            transfers[slot] = .{ .instance_id = instance.id, .chunk_id = group.chunk_id, .terrain_revision = group.terrain_revision };
            slot += 1;
        };
        return .{ .identity = .{ .world_session = 1, .kind = .construction, .id = instance.id, .lifetime = instance.lifetime }, .definition_id = instance.definition_id, .owner = instance.owner, .origin = instance.origin, .rotation = instance.rotation, .phase = instance.phase, .revision = instance.revision, .fulfilled = bits, .transfers = transfers };
    }

    fn deinit(self: Compact, allocator: std.mem.Allocator) void {
        allocator.free(self.fulfilled);
        allocator.free(self.transfers);
    }
};
const CompactUpdate = union(enum) { snapshot: Compact, delta: stream.Delta, retired: stream.Retirement };

fn reconstructCompact(a: std.mem.Allocator, state: *const runtime.State, layout: *const engine.WorldLayout, payload: Compact) !runtime.Instance {
    var value = try state.prepareInstance(a, layout, payload.identity.id, payload.definition_id, payload.owner, payload.origin, payload.rotation);
    errdefer value.deinit(a);
    @memcpy(value.fulfilled, payload.fulfilled);
    for (value.fulfilled) |byte| value.remaining -= @popCount(byte);
    value.phase = payload.phase;
    value.active = value.phase != .complete;
    value.revision = payload.revision;
    for (payload.transfers) |transfer| {
        const group = &value.target_groups[value.groupIndex(transfer.chunk_id).?];
        group.transferred = true;
        group.terrain_revision = transfer.terrain_revision;
        value.remaining_groups -= 1;
    }
    return value;
}

const Sample = struct {
    wall: i96,
    cpu: i96,
    used: usize,
    allocations: u64,

    fn begin(budget: *Budget) Sample {
        const stats = budget.stats();
        budget.peak.store(stats.used, .monotonic);
        return .{ .wall = std.Io.Clock.awake.now(std.testing.io).nanoseconds, .cpu = std.Io.Clock.cpu_thread.now(std.testing.io).nanoseconds, .used = stats.used, .allocations = stats.allocations };
    }

    fn report(self: Sample, budget: *Budget, phase: []const u8, reps: usize) void {
        const wall = std.Io.Clock.awake.now(std.testing.io).nanoseconds - self.wall;
        const cpu = std.Io.Clock.cpu_thread.now(std.testing.io).nanoseconds - self.cpu;
        const stats = budget.stats();
        std.debug.print("snapshot-payload phase={s} reps={d} wall_us_per={d:.3} cpu_us_per={d:.3} allocations_per={d:.2} retained_extra={d} peak_extra={d}\n", .{ phase, reps, @as(f64, @floatFromInt(wall)) / @as(f64, @floatFromInt(reps)) / 1000, @as(f64, @floatFromInt(cpu)) / @as(f64, @floatFromInt(reps)) / 1000, @as(f64, @floatFromInt(stats.allocations - self.allocations)) / @as(f64, @floatFromInt(reps)), stats.used - self.used, stats.peak - self.used });
    }
};

pub fn run() !void {
    var budget = Budget.init(std.heap.smp_allocator, 1024 * 1024 * 1024);
    const a = budget.allocator();
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 16, 16, 4 } });
    var state: runtime.State = .{ .layout = &layout };
    defer state.deinit(a);
    const cells = try a.alloc(blueprint.BlockType, 320_000);
    @memset(cells, .planks);
    try state.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Dense320k"), .definition = .{ .size = .{ 100, 100, 32 }, .cells = cells, .target_count = 320_000 } });
    const definition = state.definitions.get(1).?.definition;
    var instance = try state.prepareInstance(a, &layout, 1, 1, 1, .{ 31, 31, 12 }, 0);
    defer instance.deinit(a);
    // Half fulfilled: full grouping retained, but only 160k pending targets are indexed.
    @memset(instance.fulfilled[0..20_000], 255);
    instance.remaining = 160_000;
    instance.revision = 160_000;
    try std.testing.expectEqual(@as(usize, 50), instance.box_chunks.len);
    try std.testing.expectEqual(@as(usize, 50), instance.target_groups.len);
    try runtime.validateSnapshot(&layout, definition, instance);
    std.debug.print("snapshot-payload native Instance={d} Update={d} Identity={d} TargetGroup={d} Transfer={d} CompactUpdate={d} ChunkId={d} bits={d} boxes={d} groups={d} indices={d} runtime_owned={d} snapshot_charge={d} compact_building={d} compact_25_transfers={d}\n", .{ @sizeOf(runtime.Instance), @sizeOf(stream.Update), @sizeOf(stream.Identity), @sizeOf(runtime.TargetGroup), @sizeOf(runtime.Transfer), @sizeOf(CompactUpdate), @sizeOf(ChunkId), instance.fulfilled.len, instance.box_chunks.len * @sizeOf(ChunkId), instance.target_groups.len * @sizeOf(runtime.TargetGroup), instance.target_indices.len * @sizeOf(u32), instance.estimatedOwnedBytes(), @sizeOf(stream.Update) + instance.estimatedOwnedBytes(), @sizeOf(CompactUpdate) + instance.fulfilled.len, @sizeOf(CompactUpdate) + instance.fulfilled.len + 25 * @sizeOf(runtime.Transfer) });
    const payload = try Compact.clone(a, instance);
    defer payload.deinit(a);
    var equivalent = try reconstructCompact(a, &state, &layout, payload);
    defer equivalent.deinit(a);
    try runtime.validateSnapshot(&layout, definition, equivalent);
    try std.testing.expectEqualSlices(u32, instance.target_indices, equivalent.target_indices);
    try std.testing.expectEqualSlices(u8, instance.fulfilled, equivalent.fulfilled);

    // Warm each path once before collecting timing samples.
    var warm = try instance.clone(a);
    warm.deinit(a);
    var reconstruct = try state.prepareInstance(a, &layout, 1, 1, 1, instance.origin, instance.rotation);
    reconstruct.deinit(a);
    var sample = Sample.begin(&budget);
    for (0..200) |_| {
        var copy = try instance.clone(a);
        std.mem.doNotOptimizeAway(copy.target_indices);
        copy.deinit(a);
    }
    sample.report(&budget, "runtime_clone_and_free", 200);
    sample = Sample.begin(&budget);
    for (0..200) |_| {
        var copy = try stream.Snapshot.borrow(payload.identity, instance).clone(a);
        std.mem.doNotOptimizeAway(copy.target_indices);
        copy.deinit(a);
    }
    sample.report(&budget, "publication_clone_and_free", 200);
    const publication = stream.Snapshot.borrow(payload.identity, instance);
    sample = Sample.begin(&budget);
    for (0..200) |_| {
        var copy = try publication.toInstance(a);
        std.mem.doNotOptimizeAway(copy.target_indices);
        copy.deinit(a);
    }
    sample.report(&budget, "runtime_install_copy_and_free", 200);
    sample = Sample.begin(&budget);
    for (0..200) |_| {
        const compact = try Compact.clone(a, instance);
        std.mem.doNotOptimizeAway(compact.fulfilled);
        compact.deinit(a);
    }
    sample.report(&budget, "compact_publication_clone_and_free", 200);
    sample = Sample.begin(&budget);
    for (0..20) |_| {
        var copy = try reconstructCompact(a, &state, &layout, payload);
        std.mem.doNotOptimizeAway(copy.target_indices);
        copy.deinit(a);
    }
    sample.report(&budget, "initial_reconstruction_and_free", 20);
    sample = Sample.begin(&budget);
    for (0..50) |_| try runtime.validateSnapshot(&layout, definition, instance);
    sample.report(&budget, "full_snapshot_validation", 50);
    // Owned array copy plus unchanged validation. A future same-descriptor
    // resync could copy immutable grouping from its local runtime instead;
    // descriptor checking and transfer-state replacement are not implemented here.
    sample = Sample.begin(&budget);
    for (0..100) |_| {
        var copy = try publication.toInstance(a);
        try runtime.validateSnapshot(&layout, definition, copy);
        copy.deinit(a);
    }
    sample.report(&budget, "same_lifetime_copy_and_validate", 100);
    // Current client-side index preparation and validation, excluding payload
    // clone, definition certification, reservation and final publication.
    // This uses an empty source directory.
    const copy = try instance.clone(a);
    sample = Sample.begin(&budget);
    var prepared = try runtime.buildSnapshotPublication(a, &layout, definition, copy, &state);
    sample.report(&budget, "initial_index_preparation_half_pending", 1);
    std.debug.print("snapshot-payload initial_prepared_estimate={d} pending_chunks={d}\n", .{ prepared.estimatedOwnedBytes(), prepared.chunks.count() });
    prepared.deinit(a);

    @memset(instance.fulfilled, 255);
    instance.remaining = 0;
    instance.phase = .materializing;
    for (instance.target_groups[0..25], 0..) |*group, i| {
        group.transferred = true;
        group.terrain_revision = i + 1;
    }
    instance.remaining_groups = 25;
    instance.revision = 320_025;
    try runtime.validateSnapshot(&layout, definition, instance);
    const transferred = try Compact.clone(a, instance);
    defer transferred.deinit(a);
    var transferred_equivalent = try reconstructCompact(a, &state, &layout, transferred);
    defer transferred_equivalent.deinit(a);
    try runtime.validateSnapshot(&layout, definition, transferred_equivalent);
    for (instance.target_groups, transferred_equivalent.target_groups) |before, after|
        try std.testing.expectEqualDeep(before, after);
    sample = Sample.begin(&budget);
    for (0..200) |_| {
        const compact = try Compact.clone(a, instance);
        std.mem.doNotOptimizeAway(compact.transfers);
        compact.deinit(a);
    }
    sample.report(&budget, "compact_25_transfers_clone_and_free", 200);
    // Keep one publication clone live to report exact retained budget bytes.
    sample = Sample.begin(&budget);
    var retained = try stream.Snapshot.borrow(payload.identity, instance).clone(a);
    sample.report(&budget, "one_native_publication_live", 1);
    retained.deinit(a);
    sample = Sample.begin(&budget);
    const retained_compact = try Compact.clone(a, instance);
    sample.report(&budget, "one_compact_publication_live", 1);
    retained_compact.deinit(a);
}
