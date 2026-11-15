//! CPU source preparation only. Packed renderer tests separately measure CPU/queue
//! updates and check raster correctness; these timings exclude GPU execution.
const std = @import("std");
const engine = @import("engine");
const client = @import("warehouse_client.zig");
const geometry = @import("packed_geometry.zig");
const warehouse = @import("warehouse_state.zig");
const stream = @import("warehouse_stream.zig");
const layout = @import("warehouse_layout.zig");

pub fn main(init: std.process.Init) !void {
    const world_layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 128, 128, 8 } });
    for ([_]bool{ false, true }) |boundary| for ([_]usize{ 0, 64, 1024 }) |observed| for ([_]engine.voxel_chunk.BlockType{ .dirt, .country_road_adaptive, .pallet }) |material| {
        if (boundary and observed != 64) continue;
        var cache: client.Cache = .{ .world_size = world_layout.size_in_blocks };
        defer cache.deinit(init.gpa);
        _ = cache.acceptSession(1);
        var sources: geometry.Cache = .{};
        defer sources.deinit(init.gpa);
        var directory_ns: i96 = 0;
        for (0..4096) |index| {
            const record: warehouse.Record = .{
                .identity = .{ .kind = .warehouse, .world_session = 1, .id = index + 1, .lifetime = 1 },
                .geometry = try layout.Geometry.fromMinimum(world_layout.size_in_blocks, .{ @intCast(if (boundary and index == 0) world_layout.size_in_blocks[0] - 2 else (index % 64) * 32 + @as(usize, if (boundary) 30 else 8)), @intCast((index / 64) * 32 + @as(usize, if (boundary) 30 else 8)), if (boundary) 31 else 40 }, .{ 5, 5 }),
                .material = material,
                .stock = 150,
                .active = 25,
                .revision = 1,
            };
            const reference: stream.Reference = .{ .identity = record.identity, .geometry = record.geometry };
            const entry = try cache.ensure(init.gpa, reference);
            entry.record = record;
            entry.resync = false;
            entry.references = @intFromBool(index < observed);
            if (index < observed) {
                const start = std.Io.Clock.awake.now(init.io);
                try sources.retainObject(init.gpa, &world_layout, reference);
                directory_ns += start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            }
        }
        var source_bytes: usize = 0;
        var visited_objects: usize = 0;
        var visited_slots: usize = 0;
        var derive_ns: i96 = 0;
        var transient_source_capacity: usize = 0;
        const rounds = 8;
        for (0..rounds) |_| {
            const start = std.Io.Clock.awake.now(init.io);
            var iterator = sources.chunks.iterator();
            while (iterator.next()) |entry| {
                var built = try geometry.buildReferences(init.gpa, &cache, entry.value_ptr.references.items, world_layout.decodeChunkId(entry.key_ptr.*), &.{}, &.{}, .{});
                defer built.deinit(init.gpa);
                source_bytes += built.bytes();
                transient_source_capacity = @max(transient_source_capacity, built.allocatedBytes());
                visited_objects += built.visited_objects;
                visited_slots += built.visited_slots;
                std.mem.doNotOptimizeAway(built.faces.items);
                std.mem.doNotOptimizeAway(built.models.items);
                entry.value_ptr.dirty = false;
            }
            derive_ns += start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        }
        var idle_digest: usize = 0;
        const idle_start = std.Io.Clock.awake.now(init.io);
        for (0..10000) |_| {
            std.mem.doNotOptimizeAway(&sources);
            var iterator = sources.chunks.valueIterator();
            while (iterator.next()) |chunk| if (chunk.dirty) {
                idle_digest += 1;
            };
        }
        const idle_ns = idle_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        std.debug.print("packed_cpu total_objects=4096 observed={d} boundary={any} material={s} source_chunks={d} directory_us={d:.3} sweep_us={d:.3} per_observed_us={d:.3} idle_scan_us={d:.3} source_bytes={d} retained_directory_estimate={d} transient_source_capacity={d} visited_objects={d} visited_slots={d} idle_builds={d} idle_upload_bytes=0\n", .{
            observed,
            boundary,
            @tagName(material),
            sources.chunks.count(),
            @as(f64, @floatFromInt(directory_ns)) / std.time.ns_per_us,
            @as(f64, @floatFromInt(derive_ns)) / (rounds * std.time.ns_per_us),
            @as(f64, @floatFromInt(derive_ns)) / @as(f64, @floatFromInt(rounds * @max(observed, 1) * std.time.ns_per_us)),
            @as(f64, @floatFromInt(idle_ns)) / (10000 * std.time.ns_per_us),
            source_bytes / rounds,
            sources.estimatedOwnedBytes(),
            transient_source_capacity,
            visited_objects / rounds,
            visited_slots / rounds,
            idle_digest,
        });
    };
}
