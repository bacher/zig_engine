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
