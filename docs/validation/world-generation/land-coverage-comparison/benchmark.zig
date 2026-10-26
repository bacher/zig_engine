const std = @import("std");
const builtin = @import("builtin");
const Geography = @import("generation_geography.zig").Geography;
const hash = @import("generation_hash.zig");
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const cells = 512 * 256;
    for (0..3) |_| {
        var warm = try Geography.init(allocator, hash.stream(12345, .continents, 0), .{ 65536, 32768, 1024 }, .{});
        warm.deinit(allocator);
    }
    std.debug.print("mode={s} target={s}-{s} retained_bytes={d} peak_bytes={d} allocations={d} warmups=3 samples=256\n", .{ @tagName(builtin.mode), @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag), Geography.retainedBytes(cells), Geography.preparationPeakBytes(cells), Geography.preparation_allocation_count });
    var total: u64 = 0;
    var accepted: u32 = 0;
    for (0..256) |index| {
        const seed: u64 = if (index == 0) 12345 else @intCast(index - 1);
        const begin = std.Io.Clock.awake.now(init.io);
        var g = Geography.init(allocator, hash.stream(seed, .continents, 0), .{ 65536, 32768, 1024 }, .{}) catch |err| {
            const duration = begin.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            std.debug.print("seed={d} error={s} preparation_ns={d}\n", .{ seed, @errorName(err), duration });
            total += @intCast(duration);
            continue;
        };
        const duration: u64 = @intCast(begin.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        total += duration;
        accepted += 1;
        var area: u32 = 0;
        for (g.core_counts[0..g.continent_count]) |count| area += count;
        std.debug.print("seed={d} preparation_ns={d} k={d} coarse_cells={d}\n", .{ seed, duration, g.continent_count, area });
        g.deinit(allocator);
    }
    std.debug.print("accepted={d} preparation_ns_total={d}\n", .{ accepted, total });
}
