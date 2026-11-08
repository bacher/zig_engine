//! Worker-level repeated fulfillment with generated, nonresident support.
//! The WDS test hook supplies its private worker through a small comptime adapter.
//! Setup, natural-world preparation, and final checks are outside the fill timer.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const runtime = @import("blueprint_runtime.zig");
const generation = @import("world_generator.zig");
const world = @import("world.zig");
const persistence = @import("persistence/coordinator.zig");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const BlockType = blueprint.BlockType;
const ChunkId = @import("consts.zig").ChunkId;
const chunk_size = @import("consts.zig").CHUNK_SIZE;

const site_count = 16;
const floor_width = 8;
const fills_per_site = floor_width * floor_width;
const fill_count = site_count * fills_per_site;
const support_chunk_count = site_count * 4;
const target_z = chunk_size;
const floor_size: blueprint.Size = .{ floor_width, floor_width, 1 };
const fitting_capacity = 128;
const pressure_capacity = 8;
const natural_generator: generation.WorldGenerator = .{ .natural = .{ .seed = 12345 } };

const Result = struct {
    wall_ns: i96,
    cpu_ns: i96,
    cpu_clock_available: bool,
    generations: u64,
    hits: u64,
    misses: u64,
    evictions: u64,
    cache_entries: usize,
    peak_cache_entries: usize,
    cache_block_bytes: usize,
    digest: u64,
};

/// Adapter requires State plus init(allocator, layout, generator),
/// deinit(state, allocator), and fulfill(state, allocator, operation).
pub fn run(comptime Adapter: type) !void {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    const rounds = if (@import("builtin").mode == .ReleaseFast) 3 else 1;
    var expected_digest: ?u64 = null;
    for (0..rounds) |round| {
        // Reverse the middle pair so timed cases do not always favor one order.
        var baseline: Result = undefined;
        var cached: Result = undefined;
        if (round % 2 == 0) {
            baseline = try runTrial(Adapter, &layout, 0, round);
            cached = try runTrial(Adapter, &layout, fitting_capacity, round);
        } else {
            cached = try runTrial(Adapter, &layout, fitting_capacity, round);
            baseline = try runTrial(Adapter, &layout, 0, round);
        }
        try std.testing.expectEqual(baseline.digest, cached.digest);
        if (expected_digest) |expected| try std.testing.expectEqual(expected, cached.digest);
        expected_digest = cached.digest;
        try std.testing.expectEqual(@as(u64, fill_count), baseline.generations);
        try std.testing.expectEqual(@as(u64, support_chunk_count), cached.generations);
        try std.testing.expect(cached.hits >= fill_count - support_chunk_count);
        try std.testing.expectEqual(@as(u64, support_chunk_count), cached.misses);
        try std.testing.expectEqual(@as(u64, 0), cached.evictions);
        try std.testing.expectEqual(@as(usize, support_chunk_count), cached.cache_entries);
        try std.testing.expectEqual(@as(usize, support_chunk_count * @sizeOf(WorldChunkData)), cached.cache_block_bytes);
        if (@import("builtin").mode == .ReleaseFast) {
            std.debug.print("blueprint cold_support comparison sample={d} generation_reduction={d:.2}x fill_speedup={d:.2}x baseline_cpu_ms={d:.3} cached_cpu_ms={d:.3}\n", .{
                round + 1,
                @as(f64, @floatFromInt(baseline.generations)) / @as(f64, @floatFromInt(cached.generations)),
                @as(f64, @floatFromInt(baseline.wall_ns)) / @as(f64, @floatFromInt(@max(cached.wall_ns, 1))),
                milliseconds(baseline.cpu_ns),
                milliseconds(cached.cpu_ns),
            });
        }
    }

    // The same interleaved working set exceeds this cache. This is a correctness
    // and memory-bound check, with no timing or hit-rate requirement.
    const pressured = try runTrial(Adapter, &layout, pressure_capacity, rounds);
    try std.testing.expectEqual(expected_digest.?, pressured.digest);
    try std.testing.expect(pressured.evictions > 0);
    try std.testing.expect(pressured.generations > support_chunk_count);
    try std.testing.expect(pressured.generations <= fill_count);
}

fn milliseconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn position(layout: *const engine.WorldLayout, origin: [3]u32, cell_index: usize) [3]u32 {
    return runtime.worldCell(layout, origin, floor_size, 0, blueprint.cellAtIndex(floor_size, cell_index)).?;
}

/// Every site crosses two X chunks, two Y chunks, and the Z support boundary.
/// Site zero also crosses the periodic X seam. Separate sites own disjoint XY
/// columns, so exactly 64 immutable support chunks are reused by 1,024 fills.
fn chooseOrigins(prepared: *const generation.PreparedWorldGenerator) ![site_count][3]u32 {
    const layout = prepared.layout;
    var origins: [site_count][3]u32 = undefined;
    for (&origins, 0..) |*origin, site| {
        const x: u32 = if (site == 0) layout.size_in_blocks[0] - 4 else @intCast((8 + (site - 1) * 4) * chunk_size + 28);
        var found = false;
        for (0..64) |attempt| {
            const chunk_y = (@as(u32, @intCast(layout.size_in_chunks[1])) / 2 + @as(u32, @intCast(attempt * 4))) % (@as(u32, @intCast(layout.size_in_chunks[1])) - 1);
            const candidate: [3]u32 = .{ x, chunk_y * chunk_size + 28, target_z };
            if (!hasNaturalStonePlatform(prepared, candidate)) continue;
            origin.* = candidate;
            found = true;
            break;
        }
        if (!found) return error.MissingNaturalStoneSupportFixture;
    }
    return origins;
}

/// Confirm a real full stone platform for the certified recipe, including its
/// outer corner cells. These slow oracle probes do not warm the worker caches.
fn hasNaturalStonePlatform(prepared: *const generation.PreparedWorldGenerator, origin: [3]u32) bool {
    const width = prepared.layout.size_in_blocks[0];
    for (0..3) |depth| for (0..floor_width + 2) |dy| for (0..floor_width + 2) |dx| {
        const x = (@as(u64, origin[0]) + width - 1 + dx) % width;
        const y = origin[1] - 1 + @as(u32, @intCast(dy));
        const z = origin[2] - 1 - @as(u32, @intCast(depth));
        if (prepared.referenceMaterialAt(@intCast(x), y, z) != .stone) return false;
    };
    return true;
}

fn installSites(state: anytype, allocator: std.mem.Allocator, origins: *const [site_count][3]u32) !void {
    const materials = [_]BlockType{.planks} ** fills_per_site;
    const compiled = try blueprint.compile(allocator, .{ .size = floor_size, .cells = &materials }, .{ .horizontal_limit = blueprint.horizontalLimit(state.layout) });
    try std.testing.expect(compiled == .valid);
    var certified = compiled.valid;
    defer certified.deinit(allocator);
    const name = try allocator.dupe(u8, "Cold natural support");
    const definition = certified.definition.clone(allocator) catch |err| {
        allocator.free(name);
        return err;
    };
    state.blueprints.insertDefinition(allocator, .{ .id = 1, .owner = 1, .name = name, .definition = definition }) catch |err| {
        allocator.free(name);
        var owned = definition;
        owned.deinit(allocator);
        return err;
    };
    for (origins, 0..) |origin, site| {
        var instance = try state.blueprints.prepareInstance(allocator, state.layout, site + 1, 1, 1, origin, 0);
        errdefer instance.deinit(allocator);
        // Model an already excavated cavity. Only the target chunks are resident;
        // every supporting chunk remains immutable generated terrain.
        for (instance.box_chunks) |id| {
            try std.testing.expect(!state.modified_chunks.contains(id));
            try state.modified_chunks.put(allocator, id, world.WorldChunk.initEmpty());
        }
        try state.blueprints.insertInstance(allocator, state.layout, instance);
    }
}

fn runTrial(comptime Adapter: type, layout: *const engine.WorldLayout, capacity: usize, sample: usize) !Result {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var state = try Adapter.init(allocator, layout, natural_generator);
    defer Adapter.deinit(&state, allocator);
    state.generated_chunks.max_entries = @intCast(capacity);
    const origins = try chooseOrigins(&state.generator);
    try installSites(&state, allocator, &origins);
    try std.testing.expectEqual(@as(u32, support_chunk_count), state.modified_chunks.count());

    var support_ids: std.AutoHashMapUnmanaged(ChunkId, void) = .empty;
    defer support_ids.deinit(allocator);
    for (origins) |origin| for (0..fills_per_site) |cell_index| {
        var below = position(layout, origin, cell_index);
        below[2] -= 1;
        const coords, _ = world.splitBlockCoords(below);
        const id = layout.encodeChunkCoords(coords);
        try std.testing.expect(!state.modified_chunks.contains(id));
        try support_ids.put(allocator, id, {});
    };
    try std.testing.expectEqual(@as(u32, support_chunk_count), support_ids.count());
    try std.testing.expectEqual(@as(u64, 0), state.generated_chunk_count);
    try std.testing.expectEqual(@as(usize, 0), @as(usize, state.generated_chunks.count()));
    const cpu_clock_available = if (std.Io.Clock.cpu_thread.resolution(io)) |resolution| resolution.nanoseconds > 0 else |_| false;
    const cpu_start = if (cpu_clock_available) std.Io.Clock.cpu_thread.now(io).toNanoseconds() else 0;
    const wall_start = persistence.now(io);
    var peak_cache_entries: usize = 0;
    for (0..fills_per_site) |cell_index| for (origins, 0..) |origin, site| {
        const commit = try Adapter.fulfill(&state, allocator, .{
            .block = position(layout, origin, cell_index),
            .action = .{ .put = .planks },
            .blueprint = .{ .instance_id = site + 1, .cell_index = @intCast(cell_index) },
        });
        try std.testing.expectEqual(world.OperationStatus.success, commit.diagnostics.status);
        try std.testing.expect(state.blueprint_last_support_reads <= 5);
        peak_cache_entries = @max(peak_cache_entries, state.generated_chunks.count());
    };
    const wall_ns = persistence.now(io) - wall_start;
    const cpu_ns = if (cpu_clock_available) std.Io.Clock.cpu_thread.now(io).toNanoseconds() - cpu_start else 0;

    try std.testing.expectEqual(@as(u64, fill_count), state.blueprint_support_reads);
    try std.testing.expectEqual(@as(u64, fill_count), state.blueprint_fulfillment_attempts);
    try std.testing.expectEqual(@as(u64, 0), state.ordinary_validation_calls);
    try std.testing.expectEqual(@as(u32, support_chunk_count), state.modified_chunks.count());
    try std.testing.expect(peak_cache_entries <= capacity);
    try std.testing.expect(state.generated_chunks.blockBytes() <= capacity * @sizeOf(WorldChunkData));
    var supports = support_ids.keyIterator();
    while (supports.next()) |id| try std.testing.expect(!state.modified_chunks.contains(id.*));
    var digest = std.hash.Wyhash.init(0);
    for (origins, 0..) |origin, site| {
        const instance = state.blueprints.instances.get(site + 1).?;
        try std.testing.expect(!instance.active);
        try std.testing.expectEqual(@as(u32, 0), instance.remaining);
        for (instance.fulfilled) |byte| try std.testing.expectEqual(@as(u8, 255), byte);
        digest.update(instance.fulfilled);
        for (0..fills_per_site) |cell_index| {
            const block = position(layout, origin, cell_index);
            const coords, const local = world.splitBlockCoords(block);
            const chunk = state.modified_chunks.get(layout.encodeChunkCoords(coords)).?;
            const material = chunk.content.getBlock(local);
            try std.testing.expectEqual(BlockType.planks, material);
            const encoded = [_]u8{@intFromEnum(material)};
            digest.update(&encoded);
        }
    }
    const result: Result = .{
        .wall_ns = wall_ns,
        .cpu_ns = cpu_ns,
        .cpu_clock_available = cpu_clock_available,
        .generations = state.generated_chunk_count,
        .hits = state.generated_chunks.hits,
        .misses = state.generated_chunks.misses,
        .evictions = state.generated_chunks.evictions,
        .cache_entries = state.generated_chunks.count(),
        .peak_cache_entries = peak_cache_entries,
        .cache_block_bytes = state.generated_chunks.blockBytes(),
        .digest = digest.final(),
    };
    if (capacity == 0) {
        try std.testing.expectEqual(@as(u64, 0), result.hits);
        try std.testing.expectEqual(@as(usize, 0), result.cache_entries);
        try std.testing.expectEqual(@as(usize, 0), result.cache_block_bytes);
    }
    if (@import("builtin").mode == .ReleaseFast) {
        std.debug.print("blueprint cold_support profile=natural seed=12345 sample={d} capacity={d} sites={d} fills={d} support_chunks={d} resident_target_chunks={d} fill_ms={d:.3} fill_cpu_ms={d:.3} cpu_clock={s} generations={d} hits={d} misses={d} evictions={d} cache_entries={d} peak_cache_entries={d} cache_block_bytes={d} support_reads={d} ordinary_calls={d} digest={x}\n", .{
            sample + 1, capacity, site_count, fill_count, support_chunk_count, state.modified_chunks.count(), milliseconds(result.wall_ns), milliseconds(result.cpu_ns), if (result.cpu_clock_available) "thread" else "unavailable", result.generations, result.hits, result.misses, result.evictions, result.cache_entries, result.peak_cache_entries, result.cache_block_bytes, state.blueprint_support_reads, state.ordinary_validation_calls, result.digest,
        });
    }
    return result;
}
