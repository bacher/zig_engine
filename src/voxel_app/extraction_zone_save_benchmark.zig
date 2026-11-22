//! Opt-in benchmark for a post-edit capture and full reopen on a disposable world.
const std = @import("std");
const adapter = @import("world_data_service.zig").ExtractionZoneSaveBenchmark;

const layout_cases: []const struct { count: usize, size: [3]u32 } = &.{
    .{ .count = 1, .size = .{ 16, 16, 4 } },
    .{ .count = 32, .size = .{ 16, 16, 4 } },
    .{ .count = 256, .size = .{ 16, 16, 4 } },
    .{ .count = 1, .size = .{ 128, 128, 64 } },
};
const samples = 3;

test "extraction zone save and reopen benchmark" {
    for (0..samples) |i| try report(.{ .count = 0, .size = .{ 0, 0, 0 }, .occupancy = .occupied }, i);
    for (layout_cases) |layout| {
        for (std.enums.values(adapter.Occupancy)) |occupancy| {
            for (0..samples) |i| try report(.{ .count = layout.count, .size = layout.size, .occupancy = occupancy }, i);
        }
    }
}

fn report(workload: adapter.Workload, iteration: usize) !void {
    const result = try adapter.sample(workload);
    std.debug.print("\nextraction_save zones={d} size={d}x{d}x{d} occupancy={s} sample={d} claimed={d} remaining={d} dirty_sources={d} capture_wall_ms={d:.3} capture_cpu_ms={d:.3} store_open_ms={d:.3} service_restore_ms={d:.3} reopen_ms={d:.3} zone_bytes={d} wal_transaction_bytes={d} base_bytes={d}\n", .{
        workload.count,
        workload.size[0],
        workload.size[1],
        workload.size[2],
        @tagName(workload.occupancy),
        iteration + 1,
        result.claimed,
        result.remaining,
        result.dirty_sources,
        ms(result.capture_wall_ns),
        ms(result.capture_cpu_ns),
        ms(result.store_open_ns),
        ms(result.service_restore_ns),
        ms(result.store_open_ns + result.service_restore_ns),
        result.zone_bytes,
        result.wal_transaction_bytes,
        result.base_bytes,
    });
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
