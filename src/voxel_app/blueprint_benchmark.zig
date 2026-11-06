//! `zig build bench-blueprint -Doptimize=ReleaseFast`.
//! Detached copy and helper compile only; excludes chunk acquisition, application,
//! service mutation, rendering, persistence, and backing allocator page overhead.
const std = @import("std");
const blueprint = @import("blueprint.zig");
const rules = @import("block_rules.zig");
const admission = @import("blueprint_admission.zig");
const runtime = @import("blueprint_runtime.zig");
const engine = @import("engine");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const BlockType = blueprint.BlockType;

const Meter = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,

    fn note(self: *Meter, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }

    fn allocator(self: *Meter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(p: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(p));
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations += 1;
        self.note(0, len);
        return result;
    }

    fn resize(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(p));
        if (!self.backing.rawResize(memory, alignment, len, ra)) return false;
        self.note(memory.len, len);
        return true;
    }

    fn remap(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(p));
        const result = self.backing.rawRemap(memory, alignment, len, ra) orelse return null;
        self.note(memory.len, len);
        return result;
    }

    fn free(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Meter = @ptrCast(@alignCast(p));
        self.backing.rawFree(memory, alignment, ra);
        self.note(memory.len, 0);
    }
};

const Kind = enum { sparse, dense, invalid };

fn cancelSlowBenchmark(io: std.Io, token: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
    for (0..1000) |_| {
        if (done.load(.acquire)) return;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch return;
    }
    token.store(true, .release);
}

fn populate(cells: []BlockType, size: blueprint.Size, kind: Kind) void {
    @memset(cells, if (kind == .dense) .rebar else if (kind == .invalid) .stone else .none);
    if (kind != .sparse) return;
    // Ground floor establishes the full compact footprint. Two mineral towers
    // use an included 3x3x3 platform reset halfway up the 32-cell height.
    @memset(cells[0 .. @as(usize, size[0]) * size[1]], .rebar);
    for ([_][2]u32{ .{ 2, 2 }, .{ size[0] - 3, size[1] - 3 } }) |xy| {
        for (0..size[2]) |z| cells[blueprint.linearIndex(size, .{ xy[0], xy[1], @intCast(z) }).?] = .rebar;
        const reset_bottom: u32 = @min(14, size[2] - 3);
        for (reset_bottom..reset_bottom + 3) |z| for (0..3) |y| for (0..3) |x| {
            cells[blueprint.linearIndex(size, .{ xy[0] + @as(u32, @intCast(x)) - 1, xy[1] + @as(u32, @intCast(y)) - 1, @intCast(z) }).?] = .reinforced_concrete;
        };
    }
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("blueprint mode={s} BlockType={d} Failure={d} cache_entry={d} max_cells={d} cache_limit=8192\n", .{
        @tagName(@import("builtin").mode), @sizeOf(BlockType), @sizeOf(rules.Failure), rules.Validator.cacheEntrySize(), blueprint.default_max_cells,
    });
    for ([_]blueprint.Size{ .{ 10, 10, 8 }, .{ 100, 100, 32 } }) |size| {
        const volume = try blueprint.checkedVolume(size, 32767, blueprint.default_max_cells);
        const source = try init.gpa.alloc(BlockType, volume);
        defer init.gpa.free(source);
        const copy = try init.gpa.alloc(BlockType, volume);
        defer init.gpa.free(copy);
        for ([_]Kind{ .sparse, .dense, .invalid }) |kind| {
            populate(source, size, kind);
            const copy_start = std.Io.Clock.awake.now(init.io);
            @memcpy(copy, source);
            std.mem.doNotOptimizeAway(copy);
            const copy_ns = copy_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            var meter: Meter = .{ .backing = init.gpa };
            var statistics: blueprint.Statistics = .{};
            var cancel = std.atomic.Value(bool).init(false);
            var done = std.atomic.Value(bool).init(false);
            const timer = try std.Thread.spawn(.{}, cancelSlowBenchmark, .{ init.io, &cancel, &done });
            defer {
                done.store(true, .release);
                timer.join();
            }
            const start = std.Io.Clock.awake.now(init.io);
            var result = try blueprint.compile(meter.allocator(), .{ .size = size, .cells = copy }, .{ .horizontal_limit = 32767, .cancel = &cancel, .statistics = &statistics });
            const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            done.store(true, .release);
            const retained = meter.live;
            const target_count: u32 = if (result == .valid) result.valid.definition.target_count else 0;
            const status: []const u8 = if (result == .valid) "valid" else if (result == .invalid) @tagName(result.invalid.code) else "cancelled";
            if (result == .valid) result.valid.deinit(meter.allocator());
            if (meter.live != 0) return error.LeakedCompilerAllocation;
            std.debug.print("size={d}x{d}x{d} case={s} volume={d} targets={d} copy_ms={d:.3} compile_ms={d:.3} helper_peak_requested={d} retained_definition={d} allocations={d} rule_reads={d} validated={d} status={s}\n", .{
                size[0],                                               size[1],                                               size[2],    @tagName(kind), volume,            target_count,
                @as(f64, @floatFromInt(copy_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms, meter.peak, retained,       meter.allocations, statistics.rule_reads,
                statistics.validated_cells,                            status,
            });
        }
    }
    try benchmarkAdmission(init, .sparse);
    try benchmarkAdmission(init, .dense);
}

fn benchmarkAdmission(init: std.process.Init, kind: Kind) !void {
    const size: blueprint.Size = .{ 100, 100, 32 };
    const volume = try blueprint.checkedVolume(size, 32767, blueprint.default_max_cells);
    const source = try init.gpa.alloc(BlockType, volume);
    defer init.gpa.free(source);
    populate(source, size, kind);
    var compiled = try blueprint.compile(init.gpa, .{ .size = size, .cells = source }, .{ .horizontal_limit = 127 });
    if (compiled != .valid) return error.InvalidBenchmarkDefinition;
    defer compiled.valid.deinit(init.gpa);
    var snapshot_meter: Meter = .{ .backing = init.gpa };
    var snapshot: admission.Snapshot = .{ .layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }), .overlay_revision = 0 };
    defer snapshot.deinit(snapshot_meter.allocator());
    // origin87 gives halo bounds31..242 XY and31..174 Z, touching 8x8x6
    // chunks. This is the worst 384-chunk alignment for the 56-cell halo.
    for (0..6) |z| for (0..8) |y| for (0..8) |x| {
        const blocks = try snapshot_meter.allocator().create(WorldChunkData);
        blocks.* = WorldChunkData.initEmpty();
        if (z == 2) {
            for (20..23) |level| @memset(std.mem.asBytes(&blocks.blocks[level]), @intFromEnum(BlockType.stone));
        }
        const id = snapshot.layout.encodeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) });
        try snapshot.chunks.put(snapshot_meter.allocator(), id, .{ .revision = 1, .blocks = blocks });
    };
    const definition = compiled.valid.definition;
    var instance: runtime.Instance = .{
        .id = 1,
        .definition_id = 1,
        .owner = 1,
        .origin = .{ 87, 87, 87 },
        .rotation = 0,
        .remaining = definition.target_count,
        .fulfilled = try init.gpa.alloc(u8, (definition.cells.len + 7) / 8),
        .box_chunks = try runtime.boxChunks(init.gpa, &snapshot.layout, .{ 87, 87, 87 }, definition.size, 0),
    };
    defer instance.deinit(init.gpa);
    @memset(instance.fulfilled, 0);
    var meter: Meter = .{ .backing = init.gpa };
    const start = std.Io.Clock.awake.now(init.io);
    var result = try admission.prepare(meter.allocator(), &snapshot, definition, instance, .{});
    const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    if (result != .prepared) {
        if (result == .rejected) std.debug.print("admission unexpected rejection={s} cell={any} failure={any}\n", .{ @tagName(result.rejected.code), result.rejected.cell, result.rejected.failure });
        return error.AdmissionBenchmarkRejected;
    }
    const retained = meter.live;
    const foundation_reads = result.prepared.foundation_reads;
    const targets = result.prepared.validated_targets;
    const footprint_chunks = result.prepared.publication.chunks.count();
    result.prepared.deinit(meter.allocator());
    if (meter.live != 0) return error.LeakedAdmissionAllocation;
    std.debug.print("admission case={s} size=100x100x32 snapshot_chunks={d} footprint_chunks={d} targets={d} foundation_reads={d} prepare_ms={d:.3} snapshot_requested={d} snapshot_estimate={d} helper_peak_requested={d} retained_publication={d} helper_allocations={d}\n", .{
        @tagName(kind),                                        snapshot.chunks.count(), footprint_chunks,               targets,    foundation_reads,
        @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms, snapshot_meter.live,     snapshot.estimatedOwnedBytes(), meter.peak, retained,
        meter.allocations,
    });
}
