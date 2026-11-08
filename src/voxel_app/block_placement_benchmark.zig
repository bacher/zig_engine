//! Run with `zig build bench-placement -Doptimize=ReleaseFast`.
const std = @import("std");
const engine = @import("engine");
const world_module = @import("world.zig");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const transformations = @import("block_transformations.zig");

const ReadCounter = struct {
    world: *const world_module.World,
    reads: usize = 0,

    fn read(context: *anyopaque, block: [3]u32) ?engine.voxel_chunk.BlockType {
        const self: *ReadCounter = @ptrCast(@alignCast(context));
        self.reads += 1;
        const coords, const local = world_module.splitBlockCoords(block);
        const chunk = self.world.chunks.get(self.world.layout.encodeChunkCoords(coords)) orelse return null;
        return chunk.content.getBlock(local);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    var world = try world_module.World.init(allocator, &layout);
    defer world.deinit();
    const data = try allocator.create(WorldChunkData);
    data.* = WorldChunkData.initEmpty();
    for (0..4) |z| data.blocks[z] = @splat(@splat(.stone));
    var chunk = world_module.WorldChunk.initBlocks(data);
    for (4..12) |z| {
        for (20..25) |y| {
            for (20..25) |x| {
                const local: [3]u5 = .{ @intCast(x), @intCast(y), @intCast(z) };
                if (chunk.apply(allocator, local, .{ .put = .planks }) != .success) return error.SetupFailed;
                chunk.metadata.markConstructed(allocator, transformations.index(local));
            }
        }
    }
    try world.insertChunk(.{ 0, 0, 0 }, chunk);
    const operation: world_module.BlockOperation = .{ .block = .{ 25, 22, 4 }, .action = .{ .put = .planks } };
    const cells = world_module.collectConstructed(allocator, world.layout, &world.chunks, operation.block);
    defer allocator.free(cells);
    var counter: ReadCounter = .{ .world = &world };
    const checked = world_module.validateEdit(allocator, .{ .layout = world.layout, .context = &counter, .block_at = ReadCounter.read }, cells, operation);
    if (checked.status != .success) return error.ValidationFailed;
    // Warm up before timing. Every preview owns a fresh validator and its caches.
    if (world.previewOperation(operation).status != .success) return error.ValidationFailed;
    var samples: [10]u64 = undefined;
    for (&samples) |*sample| {
        const started = std.Io.Clock.awake.now(init.io);
        if (world.previewOperation(operation).status != .success) return error.ValidationFailed;
        sample.* = @intCast(started.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("200-block plank building: {d} reader calls; preview median {d:.3} ms, min {d:.3} ms ({d} samples, {s})\n", .{
        counter.reads,
        @as(f64, @floatFromInt(samples[samples.len / 2])) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(samples[0])) / std.time.ns_per_ms,
        samples.len,
        @tagName(@import("builtin").mode),
    });
    try benchmarkWindow(init, &world, operation.block);
    const maximum_layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var maximum_world = try world_module.World.init(allocator, &maximum_layout);
    defer maximum_world.deinit();
    for (1..4) |z| for (1..4) |y| {
        for (1..4) |x|
            try maximum_world.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, world_module.WorldChunk.initEmpty());
    };
    try benchmarkWindow(init, &maximum_world, .{ 80, 80, 80 });
    try benchmarkCrushedColumns(init, false);
    try benchmarkCrushedColumns(init, true);
    try benchmarkCrushedRoutes(init);
    try benchmarkCrushedReset(init);
}

/// Measure the unchanged-preview path separately from full structural validation.
fn benchmarkWindow(init: std.process.Init, world: *world_module.World, target: [3]u32) !void {
    var window = world.validationWindow(target);
    const frames_per_sample = 10000;
    var samples: [11]u64 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.awake.now(init.io);
        for (0..frames_per_sample) |_| {
            std.mem.doNotOptimizeAway(world);
            std.mem.doNotOptimizeAway(&window);
            if (!window.isCurrent(world)) return error.CacheInvalidated;
        }
        sample.* = @intCast(start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("{d}-chunk placement cache: median {d:.3} us/check, min {d:.3} us/check ({d} frames/sample, {s}; excludes raycast, validation and rendering)\n", .{
        window.chunks.count,
        @as(f64, @floatFromInt(samples[samples.len / 2])) / (frames_per_sample * std.time.ns_per_us),
        @as(f64, @floatFromInt(samples[0])) / (frames_per_sample * std.time.ns_per_us),
        frames_per_sample,
        @tagName(@import("builtin").mode),
    });
}

/// Six-cell columns keep the common old/new workload identical. The three-column
/// groups additionally offer a legal bridge at the limit of a crushed run.
fn benchmarkCrushedColumns(init: std.process.Init, bridges: bool) !void {
    const allocator = init.gpa;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    var world = try world_module.World.init(allocator, &layout);
    defer world.deinit();
    var chunk = try crushedChunk(allocator);
    const target: [3]u32 = .{ 16, 16, 9 };
    if (bridges) {
        for ([_]usize{ 8, 16, 24 }) |y| {
            for ([_]usize{ 8, 16, 24 }) |center_x| {
                for (center_x - 1..center_x + 2) |x| {
                    for (4..10) |z| {
                        if (x == target[0] and y == target[1] and z == target[2]) continue;
                        try putFixture(allocator, &chunk, x, y, z, .crushed_stone);
                    }
                }
            }
        }
    } else {
        for ([_]usize{ 8, 12, 16, 20, 24 }) |y| {
            for ([_]usize{ 8, 12, 16, 20, 24 }) |x| {
                for (4..10) |z| {
                    if (x == target[0] and y == target[1] and z == target[2]) continue;
                    try putFixture(allocator, &chunk, x, y, z, .crushed_stone);
                }
            }
        }
    }
    try world.insertChunk(.{ 0, 0, 0 }, chunk);
    try measureCrushed(init, &world, target, if (bridges) "nine run-six crushed bridges" else "25 plain six-cell crushed columns", false);
}

/// The x-axis route has height six and the y-axis route has height one; the
/// direct route is taller than one. Isolate selecting the shortest support.
fn benchmarkCrushedRoutes(init: std.process.Init) !void {
    const allocator = init.gpa;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    var world = try world_module.World.init(allocator, &layout);
    defer world.deinit();
    var chunk = try crushedChunk(allocator);
    for (15..18) |x| {
        for (4..10) |z| {
            if (x == 16 and z == 9) continue;
            try putFixture(allocator, &chunk, x, 16, z, .crushed_stone);
        }
    }
    for ([_]usize{ 15, 17 }) |y| {
        for (4..9) |z| try putFixture(allocator, &chunk, 16, y, z, .stone);
        try putFixture(allocator, &chunk, 16, y, 9, .crushed_stone);
    }
    try world.insertChunk(.{ 0, 0, 0 }, chunk);
    try measureCrushed(init, &world, .{ 16, 16, 9 }, "crushed direct + two bridge routes (root only)", true);
}

/// A new-rules-only workload: every level has independent natural-rock bridge
/// sides, allowing the center column to exceed the old six-cell run limit.
fn benchmarkCrushedReset(init: std.process.Init) !void {
    const allocator = init.gpa;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    var world = try world_module.World.init(allocator, &layout);
    defer world.deinit();
    var chunk = try crushedChunk(allocator);
    for (4..24) |z| {
        for ([_]usize{ 15, 17 }) |x| try putFixture(allocator, &chunk, x, 16, z, .stone);
        if (z < 23) try putFixture(allocator, &chunk, 16, 16, z, .crushed_stone);
    }
    try world.insertChunk(.{ 0, 0, 0 }, chunk);
    try measureCrushed(init, &world, .{ 16, 16, 23 }, "20-cell independently bridged crushed column", false);
}

fn crushedChunk(allocator: std.mem.Allocator) !world_module.WorldChunk {
    const data = try allocator.create(WorldChunkData);
    data.* = WorldChunkData.initEmpty();
    for (0..4) |z| data.blocks[z] = @splat(@splat(.stone));
    return world_module.WorldChunk.initBlocks(data);
}

fn putFixture(allocator: std.mem.Allocator, chunk: *world_module.WorldChunk, x: usize, y: usize, z: usize, material: engine.voxel_chunk.BlockType) !void {
    const local: [3]u5 = .{ @intCast(x), @intCast(y), @intCast(z) };
    if (chunk.apply(allocator, local, .{ .put = material }) != .success) return error.SetupFailed;
    if (material == .crushed_stone) chunk.metadata.markConstructed(allocator, transformations.index(local));
}

fn crushedCheck(world: *const world_module.World, operation: world_module.BlockOperation, root_only: bool) world_module.EditResult {
    return if (root_only) world_module.validateEdit(world.allocator, world.reader(), &.{}, operation) else world.previewOperation(operation);
}

fn measureCrushed(init: std.process.Init, world: *world_module.World, target: [3]u32, label: []const u8, root_only: bool) !void {
    const allocator = init.gpa;
    const operation: world_module.BlockOperation = .{ .block = target, .action = .{ .put = .crushed_stone } };
    const cells = if (root_only) try allocator.alloc(@import("block_rules.zig").Cell, 0) else world_module.collectConstructed(allocator, world.layout, &world.chunks, target);
    defer allocator.free(cells);
    var counter: ReadCounter = .{ .world = world };
    const checked = world_module.validateEdit(allocator, .{ .layout = world.layout, .context = &counter, .block_at = ReadCounter.read }, cells, operation);
    if (checked.status != .success) {
        std.debug.print("{s}: validation failed ({s})\n", .{ label, if (checked.failure) |failure| @tagName(failure.reason) else @tagName(checked.status) });
        return error.ValidationFailed;
    }
    if (crushedCheck(world, operation, root_only).status != .success) return error.ValidationFailed;
    const checks_per_sample = 100;
    var samples: [11]u64 = undefined;
    for (&samples) |*sample| {
        const started = std.Io.Clock.awake.now(init.io);
        for (0..checks_per_sample) |_| {
            if (crushedCheck(world, operation, root_only).status != .success) return error.ValidationFailed;
        }
        sample.* = @intCast(started.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("{s}: {d} reader calls; median {d:.3} us/check, min {d:.3} us/check ({d} checks/sample, {s})\n", .{
        label,
        counter.reads,
        @as(f64, @floatFromInt(samples[samples.len / 2])) / (checks_per_sample * std.time.ns_per_us),
        @as(f64, @floatFromInt(samples[0])) / (checks_per_sample * std.time.ns_per_us),
        checks_per_sample,
        @tagName(@import("builtin").mode),
    });
}
