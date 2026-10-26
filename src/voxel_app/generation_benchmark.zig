//! `zig build benchmark-generation -Doptimize=ReleaseFast -- [seed] [rounds] [half|default|double]`.
//! No pristine chunks are persisted; the cache has the production 64-column limit.
const std = @import("std");
const engine = @import("engine");
const generation = @import("world_generator.zig");
const world = @import("world.zig");
const glue = @import("world_engine_glue.zig");
const diagnostics = @import("generation_diagnostics.zig");
const Column = generation.ColumnGenerator;
const Coords = @Vector(2, i32);

/// Requested live bytes, rather than the backing allocator's page residency.
const AllocationMeter = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    maximum_request: usize = 0,
    fn note(self: *AllocationMeter, old: usize, new: usize) void {
        self.live_bytes = self.live_bytes - old + new;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        self.maximum_request = @max(self.maximum_request, new);
    }
    fn allocator(self: *AllocationMeter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(p: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *AllocationMeter = @ptrCast(@alignCast(p));
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations += 1;
        self.note(0, len);
        return result;
    }
    fn resize(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *AllocationMeter = @ptrCast(@alignCast(p));
        if (!self.backing.rawResize(memory, alignment, len, ra)) return false;
        self.resizes += 1;
        self.note(memory.len, len);
        return true;
    }
    fn remap(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *AllocationMeter = @ptrCast(@alignCast(p));
        const result = self.backing.rawRemap(memory, alignment, len, ra) orelse return null;
        self.resizes += 1;
        self.note(memory.len, len);
        return result;
    }
    fn free(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *AllocationMeter = @ptrCast(@alignCast(p));
        self.backing.rawFree(memory, alignment, ra);
        self.note(memory.len, 0);
    }
};

const Site = struct { label: []const u8, block: [2]u32, chunk_z: ?i32 = null };
fn representativeSites(prepared: *const generation.PreparedWorldGenerator) ![17]Site {
    const natural = prepared.kind.natural;
    const size = prepared.layout.size_in_blocks;
    const start = prepared.firstStart().?;
    const island = natural.geography.islands[0];
    const deposit = natural.deposits.items[0];
    const mountain_report = diagnostics.sampleMountains(prepared);
    if (mountain_report.summit == null or mountain_report.pass == null or mountain_report.gorge == null) return error.MissingMountainSite;
    var sites = [_]Site{
        .{ .label = "plains", .block = .{ start[0], start[1] } },
        .{ .label = "mainland_coast", .block = .{ start[0], start[1] } },
        .{ .label = "island_coast", .block = .{ @intCast(@mod(@as(i64, island.x) + island.radius_x - 2, size[0])), island.y } },
        .{ .label = "steep_shore", .block = .{ start[0], start[1] } },
        .{ .label = "desert_dunes", .block = .{ 0, size[1] / 2 } },
        .{ .label = "dense_forest", .block = .{ start[0], start[1] } },
        .{ .label = "deposit", .block = .{ deposit.center[0], deposit.center[1] }, .chunk_z = @intCast(deposit.center[2] / 32) },
        .{ .label = "x_seam", .block = .{ size[0] - 1, size[1] / 2 } },
        .{ .label = "ocean", .block = .{ 0, 0 } },
        .{ .label = "polar", .block = .{ size[0] / 2, 0 } },
        .{ .label = "mountain_summit", .block = mountain_report.summit.?.block },
        .{ .label = "desert_flats", .block = .{ 0, size[1] / 2 } },
        .{ .label = "mountain_pass", .block = mountain_report.pass.?.site.block },
        .{ .label = "mountain_gorge", .block = mountain_report.gorge.?.site.block },
        .{ .label = "temperate_flatland", .block = .{ start[0], start[1] } },
        .{ .label = "temperate_rolling_hills", .block = .{ start[0], start[1] } },
        .{ .label = "temperate_hilly", .block = .{ start[0], start[1] } },
    };
    std.debug.print("mountain_sites actual_high_summits={d} consecutive_bin_pairs={d} mountain_endpoint_pairs={d} influence_connected_pairs={d} connected_passes={d} pass_wall_relief={d} gorge_wall_relief={d} diagnostic_column_probes={d}\n", .{ mountain_report.high_summits_at_95_percent, mountain_report.consecutive_bin_pairs, mountain_report.mountain_endpoint_pairs, mountain_report.influence_connected_pairs, mountain_report.connected_passes, mountain_report.pass.?.wall_relief, mountain_report.gorge.?.wall_relief, mountain_report.column_probes });
    var coast_found = false;
    var dunes_found = false;
    var flats_found = false;
    var ocean_found = false;
    var temperate_found: [3]bool = @splat(false);
    var maximum_trees: usize = 0;
    var maximum_slope: u32 = 0;
    // Macro edge probes hit the actual refined coast, rather than a random
    // workload in which the optional overlay might never be evaluated.
    for (natural.geography.owners, 0..) |owner, i| {
        const mx = i % natural.geography.macro_width;
        const my = i / natural.geography.macro_width;
        if (owner == 0) {
            if (!ocean_found) {
                sites[8].block = .{ @intCast(mx * 128 + 64), @intCast(my * 128 + 64) };
                ocean_found = true;
            }
            continue;
        }
        const center = [2]u32{ @intCast(mx * 128 + 64), @intCast(my * 128 + 64) };
        const e = prepared.columnEnvironmentAt(center[0], center[1]);
        if (e.temperate_landform) |landform| {
            const index = @intFromEnum(landform);
            if (!temperate_found[index] and e.vegetation == .forest and e.coast_distance >= 512 and natural.climate.sample(center[0], center[1]).temperate_terrain == 65535) {
                const column = Column.init(prepared, .{ @intCast(center[0] / 32), @intCast(center[1] / 32) });
                if (column.column.natural.tree_count != 0) {
                    sites[14 + index].block = center;
                    temperate_found[index] = true;
                }
            }
        }
        if (e.climate == .desert and !e.water_present and e.coast_distance >= 128 and e.mountain_strength == 0) {
            if (e.desert_biome) |biome| switch (biome) {
                .dunes => if (!dunes_found) {
                    sites[4].block = center;
                    dunes_found = true;
                },
                .flats => if (!flats_found) {
                    sites[11].block = center;
                    flats_found = true;
                },
            };
        }
        if (e.vegetation == .forest and i % 17 == 0) {
            const column = Column.init(prepared, .{ @intCast(center[0] / 32), @intCast(center[1] / 32) });
            const tree_count = if (@hasField(@TypeOf(column.column.natural), "tree_count")) column.column.natural.tree_count else 0;
            if (tree_count > maximum_trees) {
                maximum_trees = tree_count;
                sites[5].block = center;
            }
        }
        if (coast_found and i % 113 != 0) continue;
        for ([_][2]u32{ .{ 16, 64 }, .{ 111, 64 }, .{ 64, 16 }, .{ 64, 111 } }) |edge| {
            const x: u32 = @intCast(mx * 128 + edge[0]);
            const y: u32 = @intCast(my * 128 + edge[1]);
            const shore = prepared.columnEnvironmentAt(x, y);
            if (shore.water_present or shore.coast_distance > 8 or shore.landmass_id == 0) continue;
            if (!coast_found and shore.climate != .frozen) {
                sites[1].block = .{ x, y };
                coast_found = true;
            }
            const neighbor = prepared.columnEnvironmentAt(@as(i64, x) + 8, y);
            const slope: u32 = @intCast(@abs(@as(i64, shore.terrain_height) - neighbor.terrain_height));
            if (slope > maximum_slope) {
                maximum_slope = slope;
                sites[3].block = .{ x, y };
            }
        }
    }
    if (!dunes_found) return error.MissingDesertDunesSite;
    if (!flats_found) return error.MissingDesertFlatsSite;
    if (!coast_found or !ocean_found) return error.MissingRepresentativeSite;
    for (temperate_found) |found| if (!found) return error.MissingTemperateSite;
    std.debug.print("representative_sites dense_forest_trees={d} maximum_shore_delta_8={d}\n", .{ maximum_trees, maximum_slope });
    return sites;
}

fn isolatedWorkload(init: std.process.Init, a: std.mem.Allocator, prepared: *const generation.PreparedWorldGenerator, site: Site, rounds: usize, samples: []u64) !void {
    const coords = Coords{ @intCast(site.block[0] / 32), @intCast(site.block[1] / 32) };
    const e = prepared.columnEnvironmentAt(site.block[0], site.block[1]);
    const z: i32 = site.chunk_z orelse @as(i32, @intCast((@max(e.terrain_height, e.sea_level) - 1) / 32));
    for (samples[0..rounds]) |*sample| {
        const begin = std.Io.Clock.awake.now(init.io);
        const column = Column.init(prepared, coords);
        sample.* = elapsed(init.io, begin);
        std.mem.doNotOptimizeAway(column);
    }
    std.debug.print("site={s} x={d} y={d} z={d} coast={d} relief={s} mountain_strength={d} climate={s} desert_biome={s} temperate_landform={s} ", .{ site.label, site.block[0], site.block[1], z, e.coast_distance, @tagName(e.relief), e.mountain_strength, @tagName(e.climate), if (e.desert_biome) |biome| @tagName(biome) else "none", if (e.temperate_landform) |landform| @tagName(landform) else "none" });
    printSamples("column_initialization", samples, 1);
    const cached = Column.init(prepared, coords);
    const adjacent_samples: usize = if (coords[1] == 0 or coords[1] + 1 == prepared.layout.size_in_chunks[1]) 0 else 128;
    std.debug.print("site={s} rounds={d} retained_environment_samples=1024 adjacent_terrain_samples={d} retained_tree_descriptors={d} chunk_voxels=32768 internal_feature_queries_excluded=true\n", .{ site.label, rounds, adjacent_samples, cached.column.natural.tree_count });
    var chunk_meter: AllocationMeter = .{ .backing = a };
    for (samples[0..rounds]) |*sample| {
        const begin = std.Io.Clock.awake.now(init.io);
        var chunk = try cached.tryGenerateChunk(chunk_meter.allocator(), z);
        sample.* = elapsed(init.io, begin);
        std.mem.doNotOptimizeAway(chunk.solid_block_count);
        chunk.deinit(chunk_meter.allocator());
    }
    printSamples("chunk_fill", samples, 1);
    const chunk = try cached.tryGenerateChunk(a, z);
    defer chunk.deinit(a);
    var masks: glue.BoundaryMasks = @splat(.{});
    for (std.enums.values(engine.voxel_chunk.Side)) |side| {
        const adjacent = world.adjacentChunk(prepared.layout, .{ coords[0], coords[1], z }, side) orelse continue;
        const neighbor_column = Column.init(prepared, .{ adjacent[0], adjacent[1] });
        const neighbor = try neighbor_column.tryGenerateChunk(a, adjacent[2]);
        defer neighbor.deinit(a);
        masks[@intFromEnum(side)] = neighbor.boundaries[@intFromEnum(side.getOpposite())];
    }
    var climate: glue.ClimateMap = undefined;
    prepared.fillClimateMap(coords, &climate);
    var mesh_meter: AllocationMeter = .{ .backing = a };
    var maximum_faces: usize = 0;
    for (samples[0..rounds]) |*sample| {
        const begin = std.Io.Clock.awake.now(init.io);
        var mesh = try glue.tryExtractChunkGeometryWithClimate(mesh_meter.allocator(), chunk, masks, &climate);
        sample.* = elapsed(init.io, begin);
        var faces: usize = 0;
        for (mesh.blocks_grouped_by_side) |side| faces += side.items.len;
        maximum_faces = @max(maximum_faces, faces);
        mesh.deinit(mesh_meter.allocator());
    }
    printSamples("meshing_prepared_chunk_and_neighbors", samples, 1);
    const current = try snapshot(a, &cached, z, true);
    std.debug.print("site={s} chunk_allocations={d} chunk_peak_requested={d} mesh_allocations={d} mesh_resizes={d} mesh_peak_requested={d} max_single_allocation={d} faces={d} face_bytes={d} exceeds_64KiB={any} digest={s}\n", .{ site.label, chunk_meter.allocations, chunk_meter.peak_live_bytes, mesh_meter.allocations, mesh_meter.resizes, mesh_meter.peak_live_bytes, mesh_meter.maximum_request, maximum_faces, current.mesh_bytes, current.mesh_bytes > 64 * 1024, std.fmt.bytesToHex(current.digest, .lower) });
}

pub const Snapshot = struct { digest: [32]u8, faces: usize = 0, mesh_bytes: usize = 0 };
pub fn snapshot(a: std.mem.Allocator, column: *const Column, z: i32, include_mesh: bool) !Snapshot {
    const prepared = column.prepared.?;
    const chunk = try column.tryGenerateChunk(a, z);
    defer chunk.deinit(a);
    var h = std.crypto.hash.Blake3.init(.{});
    const data = chunk.content.toData();
    h.update(std.mem.asBytes(&data.blocks));
    for (chunk.boundaries) |mask| for (mask.rows) |row| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, row, .little);
        h.update(&bytes);
    };
    var climate: glue.ClimateMap = undefined;
    prepared.fillClimateMap(column.coords, &climate);
    h.update(std.mem.asBytes(&climate));
    var result: Snapshot = .{ .digest = undefined };
    if (include_mesh) {
        var masks: glue.BoundaryMasks = @splat(.{});
        const coords = engine.ChunkCoords{ column.coords[0], column.coords[1], z };
        for (std.enums.values(engine.voxel_chunk.Side)) |side| {
            const adjacent = world.adjacentChunk(prepared.layout, coords, side) orelse continue;
            const neighbor_column = Column.init(prepared, .{ adjacent[0], adjacent[1] });
            const neighbor = try neighbor_column.tryGenerateChunk(a, adjacent[2]);
            defer neighbor.deinit(a);
            masks[@intFromEnum(side)] = neighbor.boundaries[@intFromEnum(side.getOpposite())];
        }
        var mesh = try glue.tryExtractChunkGeometryWithClimate(a, chunk, masks, &climate);
        defer mesh.deinit(a);
        for (mesh.blocks_grouped_by_side) |faces| {
            result.faces += faces.items.len;
            h.update(std.mem.sliceAsBytes(faces.items));
        }
        result.mesh_bytes = result.faces * @sizeOf(engine.voxel_chunk.GPU_BlockInfo);
    }
    h.final(&result.digest);
    return result;
}

const Cache = struct {
    columns: std.AutoHashMapUnmanaged(u64, Column) = .empty,
    misses: usize = 0,
    evictions: usize = 0,
    maximum_count: usize = 0,
    fn get(self: *Cache, a: std.mem.Allocator, prepared: *const generation.PreparedWorldGenerator, coords: Coords) !*const Column {
        const key = @as(u64, @intCast(coords[0])) << 32 | @as(u64, @intCast(coords[1]));
        if (!self.columns.contains(key)) {
            if (self.columns.count() >= 64) {
                self.columns.clearRetainingCapacity();
                self.evictions += 1;
            }
            try self.columns.put(a, key, Column.init(prepared, coords));
            self.misses += 1;
            self.maximum_count = @max(self.maximum_count, self.columns.count());
        }
        return self.columns.getPtr(key).?;
    }
};

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}
fn printSamples(label: []const u8, samples: []u64, count: usize) void {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const p95 = @min(samples.len - 1, (samples.len * 95 + 99) / 100 - 1);
    const median = @as(f64, @floatFromInt(samples[samples.len / 2])) / std.time.ns_per_ms;
    std.debug.print("{s}: median_ms={d:.3} p95_ms={d:.3} units_per_sample={d} throughput_units_s={d:.2}\n", .{ label, median, @as(f64, @floatFromInt(samples[p95])) / std.time.ns_per_ms, count, @as(f64, @floatFromInt(count)) * 1000 / @max(0.000001, median) });
}

fn run(init: std.process.Init, seed: u64, rounds: usize, beaches: bool, dimensions: [3]u32) ![32]u8 {
    var preparation_meter: AllocationMeter = .{ .backing = init.gpa };
    const a = preparation_meter.allocator();
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = dimensions });
    var report: generation.PreparationReport = .{};
    const prep_start = std.Io.Clock.awake.now(init.io);
    var prepared = try generation.WorldGenerator.prepareWithReport(.{ .natural = .{ .seed = seed, .settings = .{ .beaches = beaches } } }, a, &layout, &report);
    defer prepared.deinit(a);
    const prep_ns = elapsed(init.io, prep_start);
    std.debug.print("preparation_allocations={d} preparation_peak_requested={d} prepared_live_requested={d} column_bytes={d} natural_column_bytes={d} cache_column_limit=64 retained_column_upper_bound={d} chunk_scratch_stack_bytes={d}\n", .{ preparation_meter.allocations, preparation_meter.peak_live_bytes, preparation_meter.live_bytes, @sizeOf(Column), @sizeOf(@import("natural_generator.zig").NaturalColumn), @sizeOf(Column) * 64, @sizeOf(@import("world_chunk_data.zig").WorldChunkData) });
    const start = prepared.firstStart().?;
    const coords = Coords{ @intCast(start[0] / 32), @intCast(start[1] / 32) };
    const z: i32 = @intCast(start[2] / 32);
    const samples = try a.alloc(u64, rounds);
    defer a.free(samples);
    std.debug.print("identity=2/1 profile=natural seed={d} beaches={any} mode={s} target={s}-{s} preparation_ms={d:.3} peak_owned_bytes={d} attempts={d} selected={any} references={d} max_bin={d}\n", .{ seed, beaches, @tagName(@import("builtin").mode), @tagName(@import("builtin").target.cpu.arch), @tagName(@import("builtin").target.os.tag), @as(f64, @floatFromInt(prep_ns)) / std.time.ns_per_ms, report.peak_owned_bytes, report.attempts_started, report.selected_attempt, report.feature_references, report.max_bin_occupancy });
    const cached = Column.init(&prepared, coords);
    var result = try snapshot(a, &cached, z, false);
    for (samples) |*sample| {
        const begin = std.Io.Clock.awake.now(init.io);
        const cold = Column.init(&prepared, coords);
        const current = try snapshot(a, &cold, z, false);
        sample.* = elapsed(init.io, begin);
        if (!std.mem.eql(u8, &result.digest, &current.digest)) return error.RegenerationChanged;
    }
    printSamples("cold_column_plus_surface_chunk", samples, 1);
    for (samples) |*sample| {
        const begin = std.Io.Clock.awake.now(init.io);
        for (0..@as(usize, @intCast(layout.size_in_chunks[2]))) |vertical| std.mem.doNotOptimizeAway(try snapshot(a, &cached, @intCast(vertical), false));
        sample.* = elapsed(init.io, begin);
    }
    printSamples("cached_column_vertical_chunks", samples, @intCast(layout.size_in_chunks[2]));
    const representative_sites = try representativeSites(&prepared);
    var representative_digests: [representative_sites.len][32]u8 = undefined;
    for (representative_sites, 0..) |site, index| {
        try isolatedWorkload(init, a, &prepared, site, rounds, samples);
        const site_column = Column.init(&prepared, .{ @intCast(site.block[0] / 32), @intCast(site.block[1] / 32) });
        const e = prepared.columnEnvironmentAt(site.block[0], site.block[1]);
        const site_z = site.chunk_z orelse @as(i32, @intCast((@max(e.terrain_height, e.sea_level) - 1) / 32));
        representative_digests[index] = (try snapshot(a, &site_column, site_z, true)).digest;
    }
    var cache: Cache = .{};
    defer cache.columns.deinit(a);
    var baseline: [96][32]u8 = undefined;
    var sites: [96]Coords = undefined;
    for (&sites, 0..) |*site, i| site.* = .{ @intCast((@as(u32, @intCast(coords[0])) + @as(u32, @intCast(i)) * 37) % @as(u32, @intCast(layout.size_in_chunks[0]))), @intCast((@as(u32, @intCast(coords[1])) + @as(u32, @intCast(i)) * 13) % @as(u32, @intCast(layout.size_in_chunks[1]))) };
    const churn_start = std.Io.Clock.awake.now(init.io);
    for (sites, 0..) |site, i| baseline[i] = (try snapshot(a, try cache.get(a, &prepared, site), z, false)).digest;
    const first_ns = elapsed(init.io, churn_start);
    const revisit_start = std.Io.Clock.awake.now(init.io);
    var i: usize = sites.len;
    while (i > 0) {
        i -= 1;
        const current = try snapshot(a, try cache.get(a, &prepared, sites[i]), z, false);
        if (!std.mem.eql(u8, &baseline[i], &current.digest)) return error.RegenerationChanged;
    }
    const revisit_ns = elapsed(init.io, revisit_start);
    if (cache.evictions < 2 or cache.maximum_count != 64) return error.CacheWasNotEvicted;
    std.debug.print("cache_churn columns=96 forward_ms={d:.3} reverse_ms={d:.3} misses={d} clears={d} maximum_resident={d}\n", .{ @as(f64, @floatFromInt(first_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(revisit_ns)) / std.time.ns_per_ms, cache.misses, cache.evictions, cache.maximum_count });
    var reopened = try generation.WorldGenerator.prepare(.{ .natural = .{ .seed = seed, .settings = .{ .beaches = beaches } } }, a, &layout);
    defer reopened.deinit(a);
    const prepared_fingerprint = prepared.kind.natural.fingerprint();
    if (!std.mem.eql(u8, &prepared_fingerprint, &reopened.kind.natural.fingerprint())) return error.PreparedWorldChanged;
    std.debug.print("prepared_fingerprint={s} restart_matches=true\n", .{std.fmt.bytesToHex(prepared_fingerprint, .lower)});
    for (sites, 0..) |site, index| {
        const column = Column.init(&reopened, site);
        const current = try snapshot(a, &column, z, false);
        if (!std.mem.eql(u8, &baseline[index], &current.digest)) return error.RestartChanged;
    }
    var representative_index: usize = representative_sites.len;
    while (representative_index > 0) {
        representative_index -= 1;
        const site = representative_sites[representative_index];
        const site_coords = Coords{ @intCast(site.block[0] / 32), @intCast(site.block[1] / 32) };
        const e = prepared.columnEnvironmentAt(site.block[0], site.block[1]);
        const site_z = site.chunk_z orelse @as(i32, @intCast((@max(e.terrain_height, e.sea_level) - 1) / 32));
        const revisited = try snapshot(a, try cache.get(a, &prepared, site_coords), site_z, true);
        const fresh_column = Column.init(&reopened, site_coords);
        const restarted = try snapshot(a, &fresh_column, site_z, true);
        if (!std.mem.eql(u8, &representative_digests[representative_index], &revisited.digest) or !std.mem.eql(u8, &representative_digests[representative_index], &restarted.digest)) return error.DerivedRegenerationChanged;
    }
    std.debug.print("representative_replay sites={d} derived_mesh_boundary_climate_hashes_match_after_eviction_and_restart=true\n", .{representative_sites.len});
    result = try snapshot(a, &cached, z, true);
    var climate_map: glue.ClimateMap = undefined;
    prepared.fillClimateMap(coords, &climate_map);
    const before = std.Io.Clock.awake.now(init.io);
    const environment = diagnostics.sampleEnvironment(&prepared, 512, 256, 0);
    std.debug.print("mesh_start faces={d} face_bytes={d} exceeds_64KiB={any} digest={s} sampled_land_percent={d:.3} environment_samples_s={d:.2} metadata_fingerprint={x}\n", .{ result.faces, result.mesh_bytes, result.mesh_bytes > 64 * 1024, std.fmt.bytesToHex(result.digest, .lower), environment.landPercent(), @as(f64, @floatFromInt(environment.samples)) * std.time.ns_per_s / @as(f64, @floatFromInt(@max(1, elapsed(init.io, before)))), environment.fingerprint });
    return result.digest;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seed = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 12345;
    const rounds = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 3;
    if (rounds == 0 or rounds > 100) return error.InvalidRounds;
    const profile = if (args.len > 3) args[3] else "default";
    const dimensions = try diagnostics.profileDimensions(profile);
    std.debug.print("world_size_profile={s} chunks={any}\n", .{ profile, dimensions });
    _ = try run(init, seed, rounds, false, dimensions);
    _ = try run(init, seed, rounds, true, dimensions);
}
