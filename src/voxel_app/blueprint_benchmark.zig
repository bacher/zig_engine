//! `zig build bench-blueprint -Doptimize=ReleaseFast`.
//! Detached compilation and Apply preparation from resident chunks. Excludes
//! chunk acquisition, service mutation, rendering, persistence, and allocator pages.
//! Use --admission-only for six sparse/dense and none/real/planned cases;
//! --legacy-region selects the old symmetric region for benchmark comparisons only.
const std = @import("std");
const blueprint = @import("blueprint.zig");
const rules = @import("block_rules.zig");
const admission = @import("blueprint_admission.zig");
const admission_region = @import("blueprint_admission_region.zig");
const consts = @import("consts.zig");
const transforms = @import("block_transformations.zig");
const runtime = @import("blueprint_runtime.zig");
const engine = @import("engine");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const BlockType = blueprint.BlockType;

// The identical harness also runs against older baseline archives. Resolve the
// API name at compile time; the game itself only exposes prepareCertified.
const prepare_admission = if (@hasDecl(admission, "prepareCertified")) admission.prepareCertified else admission.prepare;

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

const Neighbors = enum { none, real, planned };
const AdmissionOptions = struct { legacy_region: bool = false, sample: []const u8 = "single" };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var admission_only = false;
    var options: AdmissionOptions = .{};
    var argument: usize = 1;
    while (argument < args.len) : (argument += 1) {
        if (std.mem.eql(u8, args[argument], "--admission-only")) {
            admission_only = true;
        } else if (std.mem.eql(u8, args[argument], "--legacy-region")) {
            options.legacy_region = true;
        } else if (std.mem.eql(u8, args[argument], "--sample")) {
            argument += 1;
            if (argument == args.len) return error.MissingSampleLabel;
            options.sample = args[argument];
        } else if (std.mem.eql(u8, args[argument], "--help")) {
            std.debug.print("bench-blueprint [--admission-only] [--legacy-region] [--sample LABEL]\n", .{});
            return;
        } else return error.UnknownBenchmarkArgument;
    }
    std.debug.print("blueprint sample={s} build={s} legacy_region={} admission_only={} admission_policy={s} BlockType={d} Failure={d} cache_entry={d} max_cells={d} cache_limit=8192\n", .{
        options.sample,                                                                                                                                                                @tagName(@import("builtin").mode), options.legacy_region,  admission_only,
        if (@hasField(admission.ChunkSnapshot, "constructed")) "existing-dependents" else if (@hasField(admission.Options, "cache_entries")) "new-targets" else "certified-platforms", @sizeOf(BlockType),                @sizeOf(rules.Failure), rules.Validator.cacheEntrySize(),
        blueprint.default_max_cells,
    });
    if (!admission_only) try benchmarkCompilation(init);
    for ([_]Kind{ .sparse, .dense }) |kind| {
        if (admission_only) {
            for ([_]Neighbors{ .none, .real, .planned }) |neighbors| try benchmarkAdmission(init, kind, neighbors, options);
        } else try benchmarkAdmission(init, kind, .none, options);
    }
}

fn benchmarkCompilation(init: std.process.Init) !void {
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
}

const ResidentChunk = struct {
    blocks: *WorldChunkData,
    constructed: std.ArrayList(transforms.BlockIndex) = .empty,
    index: runtime.ChunkIndex = .{},
};

/// These are resident sources, not detached copies. Their allocation and the
/// neighbor population are deliberately outside every measured phase and Meter.
const Resident = struct {
    layout: engine.WorldLayout,
    chunks: std.AutoHashMapUnmanaged(admission.ChunkId, ResidentChunk) = .empty,

    fn init(allocator: std.mem.Allocator) !Resident {
        var result: Resident = .{ .layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) };
        errdefer result.deinit(allocator);
        // origin87 gives legacy bounds31..242 XY and31..174 Z: 8x8x6
        // chunks. Both policies select from these same 384 resident records.
        for (0..6) |z| for (0..8) |y| for (0..8) |x| {
            const blocks = try allocator.create(WorldChunkData);
            blocks.* = WorldChunkData.initEmpty();
            if (z == 2) for (20..23) |level| @memset(std.mem.asBytes(&blocks.blocks[level]), @intFromEnum(BlockType.stone));
            const id = result.layout.encodeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) });
            result.chunks.put(allocator, id, .{ .blocks = blocks }) catch |err| {
                allocator.destroy(blocks);
                return err;
            };
        };
        return result;
    }

    fn deinit(self: *Resident, allocator: std.mem.Allocator) void {
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| {
            allocator.destroy(chunk.blocks);
            chunk.constructed.deinit(allocator);
            chunk.index.deinit(allocator);
        }
        self.chunks.deinit(allocator);
    }

    fn at(self: *Resident, cell: runtime.Cell) *ResidentChunk {
        return self.chunks.getPtr(self.layout.encodeChunkCoords(.{ @intCast(cell[0] / consts.CHUNK_SIZE), @intCast(cell[1] / consts.CHUNK_SIZE), @intCast(cell[2] / consts.CHUNK_SIZE) })).?;
    }

    fn populateNeighbors(self: *Resident, allocator: std.mem.Allocator, mode: Neighbors) !usize {
        if (mode == .none) return 0;
        var count: usize = 0;
        if (mode == .real) {
            for (59..215) |y| for (59..215) |x| {
                if (x >= 87 and x < 187 and y >= 87 and y < 187) continue;
                const cell: runtime.Cell = .{ @intCast(x), @intCast(y), 87 };
                const chunk = self.at(cell);
                chunk.blocks.blocks[87 % 32][y % 32][x % 32] = .rebar;
                try chunk.constructed.append(allocator, transforms.index(.{ @truncate(x), @truncate(y), 87 % 32 }));
                count += 1;
            };
        } else {
            const Strip = struct { id: u64, origin: runtime.Cell, size: blueprint.Size };
            // Six legal rectangular boxes cover the ring without overlaps.
            // Their complete indexes preserve the same per-chunk target slots
            // and instance membership that publication must clone in the game.
            for ([_]Strip{
                .{ .id = 2, .origin = .{ 59, 59, 87 }, .size = .{ 78, 28, 1 } },
                .{ .id = 3, .origin = .{ 137, 59, 87 }, .size = .{ 78, 28, 1 } },
                .{ .id = 4, .origin = .{ 59, 187, 87 }, .size = .{ 78, 28, 1 } },
                .{ .id = 5, .origin = .{ 137, 187, 87 }, .size = .{ 78, 28, 1 } },
                .{ .id = 6, .origin = .{ 59, 87, 87 }, .size = .{ 28, 100, 1 } },
                .{ .id = 7, .origin = .{ 187, 87, 87 }, .size = .{ 28, 100, 1 } },
            }) |strip| {
                if (strip.size[0] > blueprint.horizontalLimit(&self.layout) or strip.size[1] > blueprint.horizontalLimit(&self.layout)) return error.InvalidNeighborSite;
                const box_chunks = try runtime.boxChunks(allocator, &self.layout, strip.origin, strip.size, 0);
                defer allocator.free(box_chunks);
                for (box_chunks) |id| try self.chunks.getPtr(id).?.index.instances.append(allocator, strip.id);
                for (0..strip.size[1]) |y| for (0..strip.size[0]) |x| {
                    const cell: runtime.Cell = .{ strip.origin[0] + @as(u32, @intCast(x)), strip.origin[1] + @as(u32, @intCast(y)), 87 };
                    const index = &self.at(cell).index;
                    try index.lookup.put(allocator, cell, .{ .instance_id = strip.id, .cell_index = @intCast(y * strip.size[0] + x), .material = .rebar, .chunk_slot = index.targets.items.len });
                    try index.targets.append(allocator, cell);
                    count += 1;
                };
            }
        }
        if (count != 14_336) return error.IncorrectNeighborFixture;
        return count;
    }
};

/// Historical input geometry exists only in this executable, never in Apply.
fn legacyChunks(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, origin: runtime.Cell, size: blueprint.Size) ![]admission.ChunkId {
    const radius = 2 * rules.Limits.support_radius;
    var result: std.ArrayList(admission.ChunkId) = .empty;
    errdefer result.deinit(allocator);
    var unique: std.AutoHashMapUnmanaged(admission.ChunkId, void) = .empty;
    defer unique.deinit(allocator);
    var z = @divFloor(@as(i64, origin[2]) - radius, consts.CHUNK_SIZE);
    while (z <= @divFloor(@as(i64, origin[2]) + size[2] - 1 + radius, consts.CHUNK_SIZE)) : (z += 1) {
        var y = @divFloor(@as(i64, origin[1]) - radius, consts.CHUNK_SIZE);
        while (y <= @divFloor(@as(i64, origin[1]) + size[1] - 1 + radius, consts.CHUNK_SIZE)) : (y += 1) {
            var x = @divFloor(@as(i64, origin[0]) - radius, consts.CHUNK_SIZE);
            while (x <= @divFloor(@as(i64, origin[0]) + size[0] - 1 + radius, consts.CHUNK_SIZE)) : (x += 1) {
                const coords = layout.normalizeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) }) orelse continue;
                const id = layout.encodeChunkCoords(coords);
                if (unique.contains(id)) continue;
                try unique.put(allocator, id, {});
                try result.append(allocator, id);
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

fn benchmarkAdmission(init: std.process.Init, kind: Kind, neighbors: Neighbors, options: AdmissionOptions) !void {
    const size: blueprint.Size = .{ 100, 100, 32 };
    const origin: runtime.Cell = .{ 87, 87, 87 };
    const volume = try blueprint.checkedVolume(size, 32767, blueprint.default_max_cells);
    const source_cells = try init.gpa.alloc(BlockType, volume);
    defer init.gpa.free(source_cells);
    populate(source_cells, size, kind);
    var compiled = try blueprint.compile(init.gpa, .{ .size = size, .cells = source_cells }, .{ .horizontal_limit = 127 });
    if (compiled != .valid) return error.InvalidBenchmarkDefinition;
    defer compiled.valid.deinit(init.gpa);
    const definition = compiled.valid.definition;
    var source = try Resident.init(init.gpa);
    defer source.deinit(init.gpa);
    const neighbor_count = try source.populateNeighbors(init.gpa, neighbors);
    var instance: runtime.Instance = .{
        .id = 1,
        .definition_id = 1,
        .owner = 1,
        .origin = origin,
        .rotation = 0,
        .remaining = definition.target_count,
        .fulfilled = try init.gpa.alloc(u8, (definition.cells.len + 7) / 8),
        .box_chunks = try runtime.boxChunks(init.gpa, &source.layout, origin, definition.size, 0),
    };
    defer instance.deinit(init.gpa);
    @memset(instance.fulfilled, 0);

    var region_meter: Meter = .{ .backing = init.gpa };
    const region_start = std.Io.Clock.awake.now(init.io);
    const selected = if (options.legacy_region)
        try legacyChunks(region_meter.allocator(), &source.layout, origin, definition.size)
    else
        try admission_region.chunks(region_meter.allocator(), &source.layout, origin, definition.size, instance.rotation, 1024);
    const region_ns = region_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    const region_requested = region_meter.live;
    var owns_region = true;
    defer if (owns_region) region_meter.allocator().free(selected);

    var snapshot_meter: Meter = .{ .backing = init.gpa };
    var snapshot: admission.Snapshot = .{ .layout = source.layout, .overlay_revision = 0 };
    var owns_snapshot = true;
    defer if (owns_snapshot) snapshot.deinit(snapshot_meter.allocator());
    const copy_start = std.Io.Clock.awake.now(init.io);
    for (selected) |id| {
        const resident = source.chunks.getPtr(id) orelse return error.MissingResidentChunk;
        var clone: admission.ChunkSnapshot = .{ .revision = 1, .blocks = try snapshot_meter.allocator().create(WorldChunkData) };
        errdefer clone.deinit(snapshot_meter.allocator());
        clone.blocks.* = resident.blocks.*;
        clone.index = try resident.index.clone(snapshot_meter.allocator());
        if (comptime @hasField(admission.ChunkSnapshot, "constructed")) clone.constructed = try snapshot_meter.allocator().dupe(transforms.BlockIndex, resident.constructed.items);
        try snapshot.chunks.put(snapshot_meter.allocator(), id, clone);
    }
    const copy_ns = copy_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    const snapshot_requested = snapshot_meter.live;
    const snapshot_estimate = snapshot.estimatedOwnedBytes();
    const snapshot_chunks = snapshot.chunks.count();
    region_meter.allocator().free(selected);
    owns_region = false;
    if (region_meter.live != 0) return error.LeakedRegionAllocation;

    var meter: Meter = .{ .backing = init.gpa };
    const start = std.Io.Clock.awake.now(init.io);
    var result = try prepare_admission(meter.allocator(), &snapshot, definition, instance, .{});
    const prepare_ns = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    if (result != .prepared) {
        if (result == .rejected) std.debug.print("admission unexpected rejection={s} cell={any} failure={any}\n", .{ @tagName(result.rejected.code), result.rejected.cell, result.rejected.failure });
        return error.AdmissionBenchmarkRejected;
    }
    const retained = meter.live;
    const foundation_reads = result.prepared.foundation_reads;
    const targets = result.prepared.validated_targets;
    const dependents = result.prepared.validated_dependents;
    const footprint_chunks = result.prepared.publication.chunks.count();
    result.prepared.deinit(meter.allocator());
    if (meter.live != 0) return error.LeakedAdmissionAllocation;
    snapshot.deinit(snapshot_meter.allocator());
    owns_snapshot = false;
    if (snapshot_meter.live != 0) return error.LeakedSnapshotAllocation;
    const expected_targets: usize = if (@hasField(admission.Options, "cache_entries")) definition.target_count else 0;
    const expected_chunks: usize = if (options.legacy_region) 384 else if (@hasField(admission.Options, "cache_entries")) 108 else 32;
    if (targets != expected_targets or foundation_reads != 31_212 or footprint_chunks != instance.box_chunks.len or snapshot_chunks != expected_chunks) return error.IncorrectAdmissionBenchmarkCounters;
    if (dependents != (if (@hasField(admission.ChunkSnapshot, "constructed")) neighbor_count else 0)) return error.IncorrectDependentBenchmarkCount;
    std.debug.print("admission sample={s} case={s} neighbors={s} neighbor_count={d} size=100x100x32 resident_chunks=384 snapshot_chunks={d} footprint_chunks={d} validated_targets={d} validated_dependents={d} foundation_reads={d} region_ms={d:.3} copy_ms={d:.3} prepare_ms={d:.3} region_requested={d} region_peak_requested={d} region_allocations={d} snapshot_requested={d} snapshot_peak_requested={d} snapshot_estimate={d} snapshot_allocations={d} helper_peak_requested={d} retained_publication={d} helper_allocations={d}\n", .{
        options.sample,                                          @tagName(kind),                                        @tagName(neighbors),                                      neighbor_count,    snapshot_chunks,   footprint_chunks,         targets,            dependents,          foundation_reads,
        @as(f64, @floatFromInt(region_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(copy_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(prepare_ns)) / std.time.ns_per_ms, region_requested,  region_meter.peak, region_meter.allocations, snapshot_requested, snapshot_meter.peak, snapshot_estimate,
        snapshot_meter.allocations,                              meter.peak,                                            retained,                                                 meter.allocations,
    });
}
