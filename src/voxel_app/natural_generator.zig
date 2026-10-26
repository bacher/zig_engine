const std = @import("std");
const WorldLayout = @import("engine").WorldLayout;
const BlockType = @import("engine").voxel_chunk.BlockType;
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const hash = @import("generation_hash.zig");
const environment = @import("world_environment.zig");
const Geography = @import("generation_geography.zig").Geography;
const NaturalSettings = @import("generation_settings.zig").NaturalSettings;
const preparation = @import("generation_preparation.zig");
const PreparationReport = preparation.PreparationReport;
const Deposits = @import("generation_deposits.zig").Deposits;
const vegetation = @import("generation_vegetation.zig");

pub const NaturalWorld = struct {
    layout: *const WorldLayout,
    seed: u64,
    settings: NaturalSettings,
    climate: environment.ClimateField,
    geography: Geography,
    first_start: [3]u32,
    report: PreparationReport,
    deposits: Deposits = undefined,

    pub fn init(allocator: std.mem.Allocator, layout: *const WorldLayout, seed: u64, settings: NaturalSettings, report: *PreparationReport) preparation.PrepareError!NaturalWorld {
        return initWithOptions(allocator, layout, seed, settings, report, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, layout: *const WorldLayout, seed: u64, settings: NaturalSettings, report: *PreparationReport, options: preparation.PrepareOptions) preparation.PrepareError!NaturalWorld {
        const cells = try preflight(layout, seed, settings, report, options);
        return initPreflighted(allocator, layout, seed, settings, report, options, cells);
    }

    /// The allocating wrapper must run the same preflight before owning memory.
    pub fn createWithOptions(allocator: std.mem.Allocator, layout: *const WorldLayout, seed: u64, settings: NaturalSettings, report: *PreparationReport, options: preparation.PrepareOptions) preparation.PrepareError!*NaturalWorld {
        const cells = try preflight(layout, seed, settings, report, options);
        const result = allocator.create(NaturalWorld) catch |err| {
            report.category = .preparation_aborted;
            report.reason = .allocation_failed;
            return err;
        };
        errdefer allocator.destroy(result);
        result.* = try initPreflighted(allocator, layout, seed, settings, report, options, cells);
        return result;
    }

    fn preflight(layout: *const WorldLayout, seed: u64, settings: NaturalSettings, report: *PreparationReport, options: preparation.PrepareOptions) preparation.PrepareError!usize {
        return preparation.preflightNatural(seed, settings, .{ @intCast(layout.size_in_chunks[0]), @intCast(layout.size_in_chunks[1]), @intCast(layout.size_in_chunks[2]) }, @sizeOf(NaturalWorld), report, options);
    }

    /// Only the two checked entry points above may begin candidate preparation.
    fn initPreflighted(allocator: std.mem.Allocator, layout: *const WorldLayout, seed: u64, settings: NaturalSettings, report: *PreparationReport, options: preparation.PrepareOptions, cells: usize) preparation.PrepareError!NaturalWorld {
        const climate = environment.ClimateField{ .seed = hash.stream(seed, .climate, 0), .width = layout.size_in_blocks[0], .height = layout.size_in_blocks[1], .displacement = settings.climateDisplacement(layout.size_in_blocks[1]) };
        for (0..8) |attempt| {
            if (options.is_cancelled) |cancel| if (cancel(options.cancellation_context)) {
                report.category = .preparation_aborted;
                report.reason = .cancelled;
                return error.Cancelled;
            };
            report.attempts_started += 1;
            report.stage = .geography;
            report.observed = 0;
            report.limit = 0;
            if (options.abort_at_attempt == @as(u8, @intCast(attempt))) {
                report.category = .preparation_aborted;
                report.reason = options.injected_abort;
                return switch (options.injected_abort) {
                    .cancelled => error.Cancelled,
                    .allocation_failed => error.OutOfMemory,
                    .memory_budget_exceeded => error.MemoryBudgetExceeded,
                    .internal_invariant_failure => error.InternalInvariantFailure,
                    else => error.WorkBudgetExceeded,
                };
            }
            // Logical work units bound heap comparisons, fixed-cost field probes,
            // placement probes and exact deposit XY-column visits. Integer span
            // inversion inside each deposit visit has eight fixed iterations.
            report.work_units += Geography.preparationWorkBound(cells) + featureWorkBound(settings);
            if (report.work_units > options.work_budget) {
                report.category = .preparation_aborted;
                report.reason = .work_budget_exceeded;
                report.observed = report.work_units;
                report.limit = options.work_budget;
                return error.WorkBudgetExceeded;
            }
            if (attempt < options.reject_first_candidates) {
                report.rejections[attempt] = options.injected_rejection;
                report.rejection_details[attempt] = .{ .reason = options.injected_rejection, .stage = .geography };
                report.candidates_rejected += 1;
                continue;
            }
            var geography = Geography.init(allocator, hash.stream(seed, .continents, @intCast(attempt)), layout.size_in_blocks, settings) catch |err| switch (err) {
                error.OutOfMemory => {
                    report.category = .preparation_aborted;
                    report.reason = .allocation_failed;
                    return error.OutOfMemory;
                },
                error.TopologyConflict, error.RequiredFeaturePlacement => {
                    report.rejections[attempt] = if (err == error.TopologyConflict) .topology_conflict else .required_feature_placement;
                    report.rejection_details[attempt] = .{ .reason = report.rejections[attempt], .stage = .geography, .limit = if (err == error.RequiredFeaturePlacement) 2048 else 0 };
                    report.candidates_rejected += 1;
                    continue;
                },
            };
            if (cancelled(options)) {
                geography.deinit(allocator);
                report.category = .preparation_aborted;
                report.reason = .cancelled;
                return error.Cancelled;
            }
            geography.prepareMountains(climate);
            var result = NaturalWorld{ .layout = layout, .seed = seed, .settings = settings, .climate = climate, .geography = geography, .first_start = undefined, .report = report.* };
            report.stage = .first_start;
            result.first_start = result.findStart() orelse {
                geography.deinit(allocator);
                report.rejections[attempt] = .start_access_unavailable;
                report.rejection_details[attempt] = .{ .reason = .start_access_unavailable, .stage = .first_start, .limit = cells };
                report.candidates_rejected += 1;
                continue;
            };
            report.stage = .deposits;
            var observed: u64 = 0;
            result.deposits = Deposits.initObserved(&result, hash.stream(seed, .deposits, @intCast(attempt)), settings, &observed) catch |err| {
                geography.deinit(allocator);
                if (err == error.FeatureIndexCapacity) {
                    report.observed = observed;
                    report.limit = settings.feature_index_capacity;
                }
                if (err == error.RequiredFeaturePlacement) {
                    report.observed = 256;
                    report.limit = 256;
                }
                report.rejections[attempt] = switch (err) {
                    error.RequiredFeaturePlacement => .required_feature_placement,
                    error.FeatureIndexCapacity => .feature_index_capacity,
                    error.DepositValidity => .deposit_validity,
                    error.StartAccessUnavailable => .start_access_unavailable,
                };
                report.rejection_details[attempt] = .{ .reason = report.rejections[attempt], .stage = .deposits, .observed = report.observed, .limit = report.limit };
                report.candidates_rejected += 1;
                continue;
            };
            if (cancelled(options)) {
                geography.deinit(allocator);
                report.category = .preparation_aborted;
                report.reason = .cancelled;
                return error.Cancelled;
            }
            report.feature_references = result.deposits.references;
            report.max_bin_occupancy = result.deposits.maximum_bin_occupancy;
            report.category = .none;
            report.reason = .none;
            report.stage = .complete;
            report.selected_attempt = @intCast(attempt);
            result.report = report.*;
            return result;
        }
        report.category = .seed_rejected;
        report.reason = report.rejections[7];
        return error.SeedRejected;
    }

    pub fn deinit(self: *NaturalWorld, allocator: std.mem.Allocator) void {
        self.geography.deinit(allocator);
    }

    /// Explicit little-endian descriptor/macro fingerprint; no struct padding,
    /// pointers, allocator state or materialized block contents enter this hash.
    pub fn fingerprint(self: *const NaturalWorld) [32]u8 {
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update("zig-engine-generator-2-version-1-natural");
        fingerprintScalar(&digest, self.seed);
        for (self.layout.size_in_blocks) |dimension| fingerprintScalar(&digest, dimension);
        fingerprintScalar(&digest, @as(u8, @intFromBool(self.settings.beaches)));
        fingerprintScalar(&digest, self.settings.climate_displacement);
        fingerprintScalar(&digest, self.settings.island_count);
        fingerprintScalar(&digest, self.settings.large_deposits_per_resource);
        fingerprintScalar(&digest, self.settings.small_deposits_per_resource);
        fingerprintScalar(&digest, self.settings.feature_index_capacity);
        fingerprintScalar(&digest, self.report.selected_attempt.?);
        digest.update(self.geography.owners);
        for (self.geography.coastal_distance) |distance| fingerprintScalar(&digest, distance);
        fingerprintScalar(&digest, self.geography.continent_count);
        for (self.geography.core_seeds[0..self.geography.continent_count]) |core| for (core) |coordinate| fingerprintScalar(&digest, coordinate);
        for (self.geography.islands[0..self.geography.island_count]) |island| {
            fingerprintScalar(&digest, island.id);
            fingerprintScalar(&digest, island.x);
            fingerprintScalar(&digest, island.y);
            fingerprintScalar(&digest, island.radius_x);
            fingerprintScalar(&digest, island.radius_y);
        }
        for (self.geography.mountains.previous_bins[0..self.geography.continent_count]) |bins| digest.update(&bins);
        for (self.geography.mountains.next_bins[0..self.geography.continent_count]) |bins| digest.update(&bins);
        for (self.geography.mountains.peaks[0..self.geography.continent_count]) |peaks| for (peaks) |peak| {
            fingerprintScalar(&digest, @as(u8, @intFromBool(peak.active)));
            if (!peak.active) continue;
            for (peak.center) |coordinate| fingerprintScalar(&digest, coordinate);
            fingerprintScalar(&digest, peak.summit_height);
            for (peak.radii_x) |radius| fingerprintScalar(&digest, radius);
            for (peak.radii_y) |radius| fingerprintScalar(&digest, radius);
            for (peak.shape_x) |shape| fingerprintScalar(&digest, shape);
            for (peak.shape_y) |shape| fingerprintScalar(&digest, shape);
            fingerprintScalar(&digest, peak.skew_q16);
        };
        for (self.deposits.items[0..self.deposits.count]) |deposit| {
            fingerprintScalar(&digest, deposit.id);
            fingerprintScalar(&digest, @intFromEnum(deposit.resource));
            fingerprintScalar(&digest, @intFromEnum(deposit.size_class));
            fingerprintScalar(&digest, deposit.priority);
            for (deposit.center) |coordinate| fingerprintScalar(&digest, coordinate);
            for (deposit.radii) |radius| fingerprintScalar(&digest, radius);
            fingerprintScalar(&digest, deposit.effective_blocks);
        }
        for (self.first_start) |coordinate| fingerprintScalar(&digest, coordinate);
        var result: [32]u8 = undefined;
        digest.final(&result);
        return result;
    }

    pub fn baseEnvironmentAt(self: *const NaturalWorld, x: i64, y: u32) environment.ColumnEnvironment {
        var e = self.geography.atWithClimate(self.climate, x, y);
        if (self.settings.beaches and !e.water_present and e.coast_distance <= 3 and e.terrain_height <= e.sea_level + 3 and y > 0 and y + 1 < self.layout.size_in_blocks[1]) {
            var gentle = true;
            for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| {
                const nx = x + offset[0];
                const ny: u32 = @intCast(@as(i64, y) + offset[1]);
                const other = self.geography.atWithClimate(self.climate, nx, ny);
                if (@abs(@as(i64, other.terrain_height) - e.terrain_height) > 2) gentle = false;
            }
            if (gentle) e.surface_cover = .sand;
        }
        return e;
    }

    fn findStart(self: *const NaturalWorld) ?[3]u32 {
        const cell_size = @import("generation_geography.zig").macro_size;
        // Search the actual curved belt midpoints first, then alternate rows on
        // either side. Never leave the middle half of either temperate belt.
        // The widest possible belt bounds the search without retaining a map.
        const maximum_width = self.climate.height / 4 + 1 + 2 * self.climate.displacement;
        const radius = maximum_width / (4 * cell_size) + 1;
        for (0..2 * radius + 1) |row| {
            const distance: i64 = @intCast((row + 1) / 2 * cell_size);
            const offset = if (row % 2 == 1) distance else -distance;
            for (0..self.geography.macro_width) |macro_x| {
                const x: u32 = @intCast(macro_x * cell_size + cell_size / 2);
                const boundaries = self.climate.boundaries(x);
                for ([_][2]u32{ .{ boundaries[1], boundaries[2] }, .{ boundaries[3], boundaries[4] } }) |belt| {
                    const margin = (belt[1] - belt[0] + 3) / 4;
                    const midpoint = (belt[0] + belt[1] - 1) / 2;
                    const y_signed = @as(i64, midpoint / cell_size * cell_size + cell_size / 2) + offset;
                    if (y_signed < belt[0] + margin or y_signed >= belt[1] - margin) continue;
                    const y: u32 = @intCast(y_signed);
                    const owner = self.geography.owners[y / cell_size * self.geography.macro_width + macro_x];
                    if (owner == 0) continue;
                    const e = self.baseEnvironmentAt(x, y);
                    if (!startTerrainAllowed(e) or e.coast_distance < 128) continue;
                    var safe = true;
                    for ([_][2]i32{ .{ -64, 0 }, .{ 64, 0 }, .{ 0, -64 }, .{ 0, 64 } }) |delta| {
                        const near = self.baseEnvironmentAt(@as(i64, x) + delta[0], @intCast(@as(i64, y) + delta[1]));
                        if (!startTerrainAllowed(near) or near.landmass_id != owner or @abs(@as(i64, near.terrain_height) - e.terrain_height) > 4) safe = false;
                    }
                    // The live search can shift eight blocks and asks for two
                    // blocks of horizontal clearance. Check that whole patch,
                    // rather than allowing a neighboring hilly label to slip
                    // through after the preferred center has been accepted.
                    if (safe) clearance: for (0..19) |dy| for (0..19) |dx| {
                        const near = self.baseEnvironmentAt(@as(i64, x) + @as(i64, @intCast(dx)) - 9, @intCast(@as(i64, y) + @as(i64, @intCast(dy)) - 9));
                        if (!startTerrainAllowed(near)) {
                            safe = false;
                            break :clearance;
                        }
                    };
                    if (safe) return .{ x, y, e.terrain_height };
                }
            }
        }
        return null;
    }

    /// Borrowed per-fill inputs for one horizontal column, never retained in the
    /// persistent column cache. Every Z cell uses the same floor and index bin.
    const ColumnMaterialInputs = struct {
        x: i64,
        y: u32,
        environment: environment.ColumnEnvironment,
        floor_thickness: u32,
        deposit_candidates: []const u8,
    };

    pub fn materialAt(self: *const NaturalWorld, x: i64, y: u32, z: u32) BlockType {
        const e = self.baseEnvironmentAt(x, y);
        const base = self.materialFromEnvironment(x, y, z, e);
        if (base == .grass and z + 1 == e.terrain_height and vegetation.trunkRootAt(self, x, y)) return .packed_dirt;
        // A downhill crown may stand well above this column's own terrain.
        // Complete candidate geometry bounds the probe, not local ground + 8.
        if (base == .none) return vegetation.at(self, x, y, z) orelse .none;
        return base;
    }

    fn materialFromEnvironment(self: *const NaturalWorld, x: i64, y: u32, z: u32, e: environment.ColumnEnvironment) BlockType {
        // The slow point oracle evaluates inputs afresh, independently of the
        // NaturalColumn cache and the chunk fill's per-horizontal-column reuse.
        return self.materialFromColumn(.{
            .x = x,
            .y = y,
            .environment = e,
            .floor_thickness = hash.deeprockThickness(self.seed, x, y, self.layout.size_in_blocks[0]),
            .deposit_candidates = self.deposits.candidates(x, y),
        }, z);
    }

    fn materialFromColumn(self: *const NaturalWorld, column: ColumnMaterialInputs, z: u32) BlockType {
        const e = column.environment;
        if (z < column.floor_thickness) return .deeprock;
        if (z >= e.terrain_height) return if (z < e.sea_level) .water else .none;
        const depth = e.terrain_height - z - 1;
        if (e.surface_cover == .sand and depth < 5) return .sand;
        if (self.deposits.at(column.deposit_candidates, column.x, column.y, z)) |resource| return resource;
        if (e.surface_cover == .soil and depth < 5) return if (depth == 0 and !e.water_present) .grass else .packed_dirt;
        return .stone;
    }
};

fn startTerrainAllowed(e: environment.ColumnEnvironment) bool {
    // Forest labels do not forbid a start: vegetation reserves the whole local
    // clearing. Both accepted landforms have identical eligibility.
    return !e.water_present and e.climate == .temperate and e.landmass_id > 0 and e.landmass_id < 128 and
        e.mountain_strength == 0 and e.surface_cover == .soil and
        (e.temperate_landform == .flatland or e.temperate_landform == .rolling_hills);
}

fn featureWorkBound(settings: NaturalSettings) u64 {
    var bound: u64 = 1_000_000;
    for (@import("generation_deposits.zig").definitions) |definition| {
        bound += @as(u64, definition.large_radii[0] * 2 + 1) * (definition.large_radii[1] * 2 + 1) * settings.large_deposits_per_resource;
    }
    return bound;
}

fn cancelled(options: preparation.PrepareOptions) bool {
    return if (options.is_cancelled) |callback| callback(options.cancellation_context) else false;
}

fn fingerprintScalar(digest: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .little);
    digest.update(&bytes);
}

test "first start landform eligibility treats rolling and flat forest clearings equally" {
    var e: environment.ColumnEnvironment = .{ .climate = .temperate, .terrain_height = 540, .sea_level = 512, .water_present = false, .relief = .lowland, .mountain_strength = 0, .vegetation = .meadow, .geology = .sedimentary, .surface_cover = .soil, .landmass_id = 1, .coast_distance = 256 };
    for ([_]environment.TemperateLandform{ .flatland, .rolling_hills }) |landform| {
        e.temperate_landform = landform;
        for ([_]environment.VegetationId{ .meadow, .forest }) |vegetation_id| {
            e.vegetation = vegetation_id;
            try std.testing.expect(startTerrainAllowed(e));
        }
    }
    e.temperate_landform = .hilly;
    try std.testing.expect(!startTerrainAllowed(e));
    e.temperate_landform = null;
    try std.testing.expect(!startTerrainAllowed(e));
    e.temperate_landform = .flatland;
    e.mountain_strength = 1;
    try std.testing.expect(!startTerrainAllowed(e));
    e.mountain_strength = 0;
    e.landmass_id = 128;
    try std.testing.expect(!startTerrainAllowed(e));
    e.landmass_id = 1;
    e.climate = .steppe;
    try std.testing.expect(!startTerrainAllowed(e));
}

test "first starts stay in the interior of curved temperate belts at supported sizes" {
    for ([_][3]u32{ .{ 1024, 512, 16 }, .{ 2048, 1024, 32 }, .{ 4096, 2048, 64 } }) |size| {
        const layout = try WorldLayout.init(.{ .size_in_chunks = size });
        for ([_]u64{ 12345, 0, 87 }) |seed| {
            var report: PreparationReport = .{};
            var world = try NaturalWorld.init(std.testing.allocator, &layout, seed, .{}, &report);
            defer world.deinit(std.testing.allocator);
            const start = world.first_start;
            const b = world.climate.boundaries(start[0]);
            const lower = if (start[1] < b[2]) b[1] else b[3];
            const upper = if (start[1] < b[2]) b[2] else b[4];
            const width = upper - lower;
            try std.testing.expectEqual(environment.ClimateId.temperate, world.climate.at(start[0], start[1]));
            try std.testing.expect(@as(u64, start[1] - lower) * 4 >= width);
            try std.testing.expect(@as(u64, upper - 1 - start[1]) * 4 >= width);
            // The authoritative standing-space search may shift by eight blocks.
            // Check its entire horizontal search/clearance area, including X wrap.
            for (0..19) |dy| for (0..19) |dx| {
                const near = world.baseEnvironmentAt(@as(i64, start[0]) + @as(i64, @intCast(dx)) - 9, @intCast(@as(i64, start[1]) + @as(i64, @intCast(dy)) - 9));
                try std.testing.expectEqual(environment.ClimateId.temperate, near.climate);
                try std.testing.expect(near.temperate_landform == .flatland or near.temperate_landform == .rolling_hills);
                try std.testing.expect(!near.water_present and near.mountain_strength == 0 and near.surface_cover == .soil);
            };
            const e = world.baseEnvironmentAt(start[0], start[1]);
            try std.testing.expect(!e.water_present and e.landmass_id > 0 and e.landmass_id < 128);
            try std.testing.expectEqual(environment.ReliefId.lowland, e.relief);
            try std.testing.expect(e.temperate_landform == .flatland or e.temperate_landform == .rolling_hills);
            try std.testing.expect(e.coast_distance >= 128);
            try std.testing.expectEqualDeep(start, world.findStart().?);
        }
    }
}

test "finite resource populations have exact retained quantities and large source dominance" {
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    var report: PreparationReport = .{};
    var world = try NaturalWorld.init(allocator, &layout, 12345, .{}, &report);
    defer world.deinit(allocator);
    var large: [5]u64 = @splat(0);
    var small: [5]u64 = @splat(0);
    var population: [5]u32 = @splat(0);
    var large_enumerated = false;
    for (world.deposits.items[0..world.deposits.count]) |d| {
        const resource = @intFromEnum(d.resource);
        try std.testing.expect(d.effective_blocks > 0);
        if (d.size_class == .large) {
            large[resource] += d.effective_blocks;
            population[resource] += 1;
        } else {
            try std.testing.expect(d.resource != .metal_ore and d.resource != .limestone);
            small[resource] += d.effective_blocks;
        }
        const e = world.baseEnvironmentAt(d.center[0], d.center[1]);
        if (d.resource == .metal_ore) try std.testing.expectEqual(environment.ReliefId.mountain, e.relief);
        if (d.resource != .metal_ore) try std.testing.expectEqual(environment.GeologyId.sedimentary, e.geology);
        if (d.size_class == .large and (d.resource != .clay or large_enumerated)) continue;
        if (d.size_class == .large) large_enumerated = true;
        var actual: u64 = 0;
        var dy: i64 = -@as(i64, d.radii[1]);
        while (dy <= d.radii[1]) : (dy += 1) {
            var dx: i64 = -@as(i64, d.radii[0]);
            while (dx <= d.radii[0]) : (dx += 1) {
                const x = @as(i64, d.center[0]) + dx;
                const y: u32 = @intCast(@as(i64, d.center[1]) + dy);
                const host = world.baseEnvironmentAt(x, y);
                for (d.center[2] - d.radii[2]..d.center[2] + d.radii[2] + 1) |z| {
                    if (!d.contains(x, y, @intCast(z), layout.size_in_blocks[0])) continue;
                    if (world.materialFromEnvironment(x, y, @intCast(z), host) == @import("generation_deposits.zig").definitions[resource].block) actual += 1;
                }
            }
        }
        try std.testing.expectEqual(d.effective_blocks, actual);
    }
    for (0..5) |resource| {
        try std.testing.expectEqual(@as(u32, world.settings.large_deposits_per_resource), population[resource]);
        try std.testing.expect(large[resource] >= 9 * small[resource]);
    }
    try std.testing.expect(large_enumerated);
    for (world.deposits.items[world.deposits.count - 3 .. world.deposits.count]) |d| {
        try std.testing.expectEqual(@import("generation_deposits.zig").SizeClass.starter, d.size_class);
        try std.testing.expect(@abs(hash.distanceX(d.center[0], world.first_start[0], layout.size_in_blocks[0])) <= 24);
        try std.testing.expect(@abs(@as(i64, d.center[1]) - world.first_start[1]) <= 24);
        const e = world.baseEnvironmentAt(d.center[0], d.center[1]);
        try std.testing.expect(e.terrain_height - (d.center[2] + d.radii[2]) <= 4);
    }
}

test "trees retain complete nonintersecting shapes and climate clearance" {
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    var report: PreparationReport = .{};
    var world = try NaturalWorld.init(allocator, &layout, 12345, .{}, &report);
    defer world.deinit(allocator);
    var forest_sites: usize = 0;
    var meadow_sites: usize = 0;
    var forest_trees: usize = 0;
    var meadow_trees: usize = 0;
    var complete_tree_seen = false;
    var boundary_tree_seen = false;
    var vertical_tree_seen = false;
    for (world.geography.owners, 0..) |owner, i| {
        if (owner == 0 or i % 41 != 0) continue;
        const x: u32 = @intCast(i % world.geography.macro_width * 128 + 64);
        const y: u32 = @intCast(i / world.geography.macro_width * 128 + 64);
        const e = world.baseEnvironmentAt(x, y);
        if (e.climate != .temperate or e.relief == .mountain or e.water_present) continue;
        const complete_features = complete_tree_seen and boundary_tree_seen and vertical_tree_seen;
        if (complete_features and e.vegetation == .forest and forest_sites >= 20) continue;
        if (complete_features and e.vegetation == .meadow and meadow_sites >= 20) continue;
        const column = NaturalColumn.init(&world, .{ @intCast(x / 32), @intCast(y / 32) });
        if (e.vegetation == .forest and forest_sites < 20) {
            forest_sites += 1;
            forest_trees += column.tree_count;
        }
        if (e.vegetation == .meadow and meadow_sites < 20) {
            meadow_sites += 1;
            meadow_trees += column.tree_count;
        }
        for (column.trees[0..column.tree_count], 0..) |tree, index| {
            try std.testing.expect(tree.trunk_height == 4 or tree.trunk_height == 5);
            try std.testing.expectEqualDeep(tree, vegetation.eligible(&world, tree.cell[0] - layout.size_in_blocks[0] / 8, tree.cell[1]).?);
            try std.testing.expect(vegetation.accepted(&world, tree));
            for (column.trees[index + 1 .. column.tree_count]) |other| try std.testing.expect(@abs(hash.distanceX(tree.root[0], other.root[0], layout.size_in_blocks[0])) > 5 or @abs(@as(i64, tree.root[1]) - other.root[1]) > 5);
            for (0..5) |oy| for (0..5) |ox| {
                const tx = @as(i64, tree.root[0]) + @as(i64, @intCast(ox)) - 2;
                const ty: u32 = @intCast(@as(i64, tree.root[1]) + @as(i64, @intCast(oy)) - 2);
                const under = world.baseEnvironmentAt(tx, ty);
                try std.testing.expect(under.climate != .frozen and under.climate != .desert and !under.water_present);
                const bottom = tree.root[2] + if (ox == 2 and oy == 2) @as(u32, 0) else tree.trunk_height - 2;
                try std.testing.expect(under.terrain_height <= bottom);
            };
            if (!complete_tree_seen or !boundary_tree_seen or (!vertical_tree_seen and tree.root[2] % 32 + tree.trunk_height + 2 > 32)) {
                try expectTreeReassembly(&world, tree);
                complete_tree_seen = true;
                if (tree.root[0] % 32 < 2 or tree.root[0] % 32 > 29 or tree.root[1] % 32 < 2 or tree.root[1] % 32 > 29 or tree.root[2] % 32 + tree.trunk_height + 2 > 32) boundary_tree_seen = true;
                if (tree.root[2] % 32 + tree.trunk_height + 2 > 32) vertical_tree_seen = true;
            }
        }
        if (forest_sites >= 20 and meadow_sites >= 20 and boundary_tree_seen and vertical_tree_seen) break;
    }
    try std.testing.expect(complete_tree_seen and boundary_tree_seen and vertical_tree_seen);
    try std.testing.expect(forest_sites >= 10 and meadow_sites >= 10);
    try std.testing.expect(forest_trees * meadow_sites > 3 * meadow_trees * forest_sites);
}

test "whole trees reconstruct across the X seam on protected mainland" {
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 64, 64, 4 } });
    var owners = [_]u8{0} ** 256;
    var coarse = [_]u16{0} ** 256;
    for (2..14) |y| for (0..8) |column| {
        const x = (column + 12) % 16;
        owners[y * 16 + x] = 1;
        coarse[y * 16 + x] = @intCast(@min(column + 1, 8 - column, y - 1, 14 - y));
    };
    // A fixed seam-crossing mainland keeps the whole-tree test independent of
    // whether a particular random continent happens to reach X=0 this version.
    var world = NaturalWorld{
        .layout = &layout,
        .seed = 12345,
        .settings = .{},
        .climate = .{ .seed = hash.stream(12345, .climate, 0), .width = 2048, .height = 2048, .displacement = (NaturalSettings{}).climateDisplacement(2048) },
        .geography = .{ .seed = hash.stream(12345, .continents, 0), .width = 2048, .height = 2048, .depth = 128, .sea_level = 48, .continent_count = 1, .island_count = 0, .macro_width = 16, .macro_height = 16, .owners = &owners, .coastal_distance = &coarse },
        .first_start = .{ 256, 640, 48 },
        .report = .{ .selected_attempt = 0 },
        .deposits = .{ .width = 2048, .height = 2048 },
    };
    world.geography.core_seeds[0] = .{ 1, 8 };
    try world.geography.prepareCoast(allocator);
    defer world.geography.coast_field.deinit(allocator);
    var seam_seen = false;
    for (0..layout.size_in_blocks[1] / 8) |cell_y| {
        for ([_]i64{ 0, layout.size_in_blocks[0] / 8 - 1 }) |cell_x| {
            const tree = vegetation.eligible(&world, cell_x, @intCast(cell_y)) orelse continue;
            if (tree.root[0] >= 2 and tree.root[0] < layout.size_in_blocks[0] - 2) continue;
            if (!vegetation.accepted(&world, tree)) continue;
            try std.testing.expectEqualDeep(tree, vegetation.eligible(&world, tree.cell[0] - layout.size_in_blocks[0] / 8, tree.cell[1]).?);
            const across: i64 = if (tree.root[0] < 2) -1 else layout.size_in_blocks[0];
            try std.testing.expect(tree.blockAt(across, tree.root[1], tree.root[2] + tree.trunk_height - 1, layout.size_in_blocks[0]) != null);
            try expectTreeReassembly(&world, tree);
            seam_seen = true;
            break;
        }
        if (seam_seen) break;
    }
    try std.testing.expect(seam_seen);
}

pub const NaturalColumn = struct {
    world: *const NaturalWorld,
    coords: @Vector(2, i32),
    environments: [32][32]environment.ColumnEnvironment,
    maximum_occupancy: u32,
    minimum_height: u32,
    minimum_adjacent_height: u32,
    trees: [64]vegetation.Tree = undefined,
    tree_count: u8 = 0,

    pub fn init(world: *const NaturalWorld, coords: @Vector(2, i32)) NaturalColumn {
        var self = NaturalColumn{ .world = world, .coords = coords, .environments = undefined, .maximum_occupancy = 0, .minimum_height = world.layout.size_in_blocks[2], .minimum_adjacent_height = world.layout.size_in_blocks[2] };
        const x = @as(i64, coords[0]) * 32;
        const y: u32 = @intCast(@as(i64, coords[1]) * 32);
        for (0..32) |ly| for (0..32) |lx| {
            const e = world.baseEnvironmentAt(x + @as(i64, @intCast(lx)), y + @as(u32, @intCast(ly)));
            self.environments[ly][lx] = e;
            self.maximum_occupancy = @max(self.maximum_occupancy, @max(e.terrain_height, e.sea_level));
            self.minimum_height = @min(self.minimum_height, e.terrain_height);
        };
        if (y == 0 or y + 32 == world.layout.size_in_blocks[1]) self.minimum_adjacent_height = 0 else for (0..32) |offset| {
            const i: u32 = @intCast(offset);
            self.minimum_adjacent_height = @min(self.minimum_adjacent_height, world.baseEnvironmentAt(x - 1, y + i).terrain_height);
            self.minimum_adjacent_height = @min(self.minimum_adjacent_height, world.baseEnvironmentAt(x + 32, y + i).terrain_height);
            self.minimum_adjacent_height = @min(self.minimum_adjacent_height, world.baseEnvironmentAt(x + i, y - 1).terrain_height);
            self.minimum_adjacent_height = @min(self.minimum_adjacent_height, world.baseEnvironmentAt(x + i, y + 32).terrain_height);
        }
        self.tree_count = @intCast(vegetation.collect(world, coords, &self.trees));
        for (self.trees[0..self.tree_count]) |tree| self.maximum_occupancy = @max(self.maximum_occupancy, tree.root[2] + tree.trunk_height + 2);
        return self;
    }

    pub fn generateData(self: *const NaturalColumn, chunk_z: i32) WorldChunkData {
        var data = WorldChunkData.initEmpty();
        for (0..32) |ly| for (0..32) |lx| {
            const x = @as(i64, self.coords[0]) * 32 + @as(i64, @intCast(lx));
            const y: u32 = @intCast(@as(i64, self.coords[1]) * 32 + @as(i64, @intCast(ly)));
            const column: NaturalWorld.ColumnMaterialInputs = .{
                .x = x,
                .y = y,
                .environment = self.environments[ly][lx],
                .floor_thickness = hash.deeprockThickness(self.world.seed, x, y, self.world.layout.size_in_blocks[0]),
                .deposit_candidates = self.world.deposits.candidates(x, y),
            };
            for (0..32) |lz| {
                const z: u32 = @intCast(@as(i64, chunk_z) * 32 + @as(i64, @intCast(lz)));
                data.blocks[lz][ly][lx] = self.world.materialFromColumn(column, z);
            }
        };
        const width = self.world.layout.size_in_blocks[0];
        const chunk_x = @as(i64, self.coords[0]) * 32;
        const chunk_y = @as(i64, self.coords[1]) * 32;
        const chunk_z_base = @as(i64, chunk_z) * 32;
        for (self.trees[0..self.tree_count]) |tree| {
            for (0..8) |dz| for (0..5) |dy| for (0..5) |dx| {
                const x = @as(i64, tree.root[0]) + @as(i64, @intCast(dx)) - 2;
                const y: u32 = @intCast(@as(i64, tree.root[1]) + @as(i64, @intCast(dy)) - 2);
                const z = tree.root[2] + @as(u32, @intCast(dz));
                const block = tree.blockAt(x, y, z, width) orelse continue;
                const lx = hash.distanceX(x, chunk_x, width);
                const ly = @as(i64, y) - chunk_y;
                const lz = @as(i64, z) - chunk_z_base;
                if (lx >= 0 and lx < 32 and ly >= 0 and ly < 32 and lz >= 0 and lz < 32) data.blocks[@intCast(lz)][@intCast(ly)][@intCast(lx)] = block;
            };
            const lx = hash.distanceX(tree.root[0], chunk_x, width);
            const ly = @as(i64, tree.root[1]) - chunk_y;
            const lz = @as(i64, tree.root[2]) - 1 - chunk_z_base;
            if (lx >= 0 and lx < 32 and ly >= 0 and ly < 32 and lz >= 0 and lz < 32 and data.blocks[@intCast(lz)][@intCast(ly)][@intCast(lx)] == .grass) data.blocks[@intCast(lz)][@intCast(ly)][@intCast(lx)] = .packed_dirt;
        }
        return data;
    }
};

fn expectTreeReassembly(world: *const NaturalWorld, tree: vegetation.Tree) !void {
    var cached_coords: [8][3]u32 = undefined;
    var cached_data: [8]WorldChunkData = undefined;
    var count: usize = 0;
    for (0..8) |dz| for (0..5) |oy| for (0..5) |ox| {
        const tx = @as(i64, tree.root[0]) + @as(i64, @intCast(ox)) - 2;
        const ty: u32 = @intCast(@as(i64, tree.root[1]) + @as(i64, @intCast(oy)) - 2);
        const tz = tree.root[2] + @as(u32, @intCast(dz));
        const expected = tree.blockAt(tx, ty, tz, world.layout.size_in_blocks[0]) orelse continue;
        const canonical_x = hash.wrappedX(tx, world.layout.size_in_blocks[0]);
        const coords = [3]u32{ canonical_x / 32, ty / 32, tz / 32 };
        var index: usize = 0;
        while (index < count and !std.meta.eql(coords, cached_coords[index])) : (index += 1) {}
        if (index == count) {
            const adjacent = NaturalColumn.init(world, .{ @intCast(coords[0]), @intCast(coords[1]) });
            cached_coords[count] = coords;
            cached_data[count] = adjacent.generateData(@intCast(coords[2]));
            count += 1;
        }
        try std.testing.expectEqual(expected, cached_data[index].blocks[tz % 32][ty % 32][canonical_x % 32]);
    };
}
