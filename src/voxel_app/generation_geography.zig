const std = @import("std");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");
const CoastApprox = @import("generation_coast_approx.zig").CoastApprox;
const Settings = @import("generation_settings.zig").NaturalSettings;
const desert = @import("generation_desert.zig");
const Mountains = @import("generation_mountains.zig").Mountains;

pub const Island = struct { id: u8, x: u32, y: u32, radius_x: u32, radius_y: u32 };
pub const macro_size = 128;
pub const Geography = struct {
    seed: u64,
    width: u32,
    height: u32,
    depth: u32,
    sea_level: u32,
    continent_count: u8,
    island_count: u8,
    islands: [32]Island = undefined,
    macro_width: u32,
    macro_height: u32,
    /// Zero water, 1..5 connected protected mainland core ownership.
    owners: []u8,
    coastal_distance: []u16,
    coast_field: CoastApprox = undefined,
    core_seeds: [5][2]u32 = undefined,
    core_counts: [5]u32 = @splat(0),
    mountains: Mountains = .{ .width = 1, .height = 1, .sea_level = 0, .continent_count = 0 },

    pub const InitError = error{ OutOfMemory, TopologyConflict, RequiredFeaturePlacement };

    pub const preparation_allocation_count: usize = 7;

    pub fn macroCellCount(dimensions_in_chunks: [3]u32) usize {
        return @as(usize, dimensions_in_chunks[0] / 4) * (dimensions_in_chunks[1] / 4);
    }

    pub fn retainedBytes(cells: usize) usize {
        return cells * (@sizeOf(u8) + @sizeOf(u16) + CoastApprox.retained_bytes_per_cell);
    }

    pub fn preparationPeakBytes(cells: usize) usize {
        // Owners/distances coexist with costs, pending owners, heap IDs and
        // heap positions. All four scratch arrays are freed before features.
        const scratch_phase_per_cell = @sizeOf(u8) + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u8) + 2 * @sizeOf(u32);
        return @max(cells * scratch_phase_per_cell, retainedBytes(cells));
    }

    pub fn preparationWorkBound(cells: usize) u64 {
        return @as(u64, cells) * (128 + CoastApprox.build_probe_bound_per_cell) + Mountains.preparationWorkBound(cells);
    }

    /// Explicit fixture entry point. Call once after the ownership and macro
    /// distance arrays are final; init prepares this before returning a world.
    pub fn prepareCoast(self: *Geography, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        self.coast_field = try CoastApprox.init(allocator, self.seed, self.width, self.height, self.owners, self.coastal_distance);
    }

    /// Uses the actual root-seeded climate field; no independent climate seed.
    /// Runtime preparation calls this once after ownership and coast are final.
    pub fn prepareMountains(self: *Geography, climate: env.ClimateField) void {
        self.mountains = Mountains.prepare(.{
            .seed = self.seed,
            .width = self.width,
            .height = self.height,
            .depth = self.depth,
            .sea_level = self.sea_level,
            .continent_count = self.continent_count,
            .core_seeds = self.core_seeds,
            .owners = self.owners,
            .coastal_distance = self.coastal_distance,
            .climate = climate,
        });
    }

    pub fn init(allocator: std.mem.Allocator, seed: u64, size: [3]u32, settings: Settings) InitError!Geography {
        const mw = size[0] / macro_size;
        const mh = size[1] / macro_size;
        const count = @as(usize, mw) * mh;
        const owners = try allocator.alloc(u8, count);
        errdefer allocator.free(owners);
        @memset(owners, 0);
        const distances = try allocator.alloc(u16, count);
        errdefer allocator.free(distances);
        @memset(distances, 0);
        var self = Geography{ .seed = seed, .width = size[0], .height = size[1], .depth = size[2], .sea_level = size[2] / 2, .continent_count = @intCast(3 + hash.mix(seed) % 3), .island_count = settings.island_count, .macro_width = mw, .macro_height = mh, .owners = owners, .coastal_distance = distances };
        {
            const costs = try allocator.alloc(u32, count);
            defer allocator.free(costs);
            @memset(costs, std.math.maxInt(u32));
            const pending = try allocator.alloc(u8, count);
            defer allocator.free(pending);
            @memset(pending, 0);
            const heap_ids = try allocator.alloc(u32, count);
            defer allocator.free(heap_ids);
            const positions = try allocator.alloc(u32, count);
            defer allocator.free(positions);
            @memset(positions, std.math.maxInt(u32));
            var heap = Heap{ .ids = heap_ids, .positions = positions, .costs = costs };
            const horizon = growthHorizon(count, self.continent_count);
            for (0..self.continent_count) |i| {
                const h = hash.mix(seed +% i);
                const sector = mw / self.continent_count;
                const base: i64 = @intCast((i * 2 + 1) * mw / (@as(usize, self.continent_count) * 2));
                const jitter = @as(i64, @intCast(h % @max(1, sector / 2))) - @as(i64, sector / 4);
                const sx: u32 = @intCast(@mod(base + jitter, mw));
                const sy: u32 = mh / 4 + @as(u32, @intCast((h >> 16) % @max(1, mh / 2)));
                const index = sy * mw + sx;
                self.core_seeds[i] = .{ sx, sy };
                pending[index] = @intCast(i + 1);
                costs[index] = @intCast((h >> 32) % @max(1, horizon / 40));
                heap.insert(index);
            }
            while (heap.pop()) |index| {
                if (costs[index] > horizon) break;
                const x = index % mw;
                const y = index / mw;
                if (y == 0 or y + 1 == mh) continue;
                const owner = pending[index];
                var permitted = true;
                var has_parent = false;
                for (0..3) |oy| for (0..3) |ox| {
                    const nx: u32 = @intCast(@mod(@as(i64, x) + @as(i64, @intCast(ox)) - 1, mw));
                    const ny: u32 = @intCast(@as(i64, y) + @as(i64, @intCast(oy)) - 1);
                    const neighbor = owners[ny * mw + nx];
                    if (neighbor != 0 and neighbor != owner) permitted = false;
                    if ((ox == 1 or oy == 1) and neighbor == owner) has_parent = true;
                };
                const root = self.core_seeds[owner - 1];
                if (!permitted or (!has_parent and !(root[0] == x and root[1] == y))) continue;
                owners[index] = owner;
                self.core_counts[owner - 1] += 1;
                // Coherent traversal costs deform the growing fronts into broad
                // lobes and bays. Probe once per accepted cell, then share its
                // positive cost across the four outgoing cardinal edges.
                const field = hash.field2(hash.mix(seed ^ 0x47524f575448), x * macro_size, y * macro_size, size[0], @max(256, size[1] / 8));
                const edge: u32 = @intCast(24 + @divTrunc((field + 65535) * 144, 131070) + @as(i64, @intCast(hash.at(seed, x, y) % 35)));
                const neighbors = [_]u32{ y * mw + (x + mw - 1) % mw, y * mw + (x + 1) % mw, (y - 1) * mw + x, (y + 1) * mw + x };
                for (neighbors) |neighbor| {
                    if (owners[neighbor] != 0 or heap.positions[neighbor] == std.math.maxInt(u32) - 1) continue;
                    const next = costs[index] + edge;
                    if (next < costs[neighbor] or (next == costs[neighbor] and owner < pending[neighbor])) {
                        costs[neighbor] = next;
                        pending[neighbor] = owner;
                        heap.insert(neighbor);
                    }
                }
            }
            // Land fraction emerges from the growth horizon; it is never an
            // acceptance gate. Every intended continent still needs a substantial
            // connected core, even when competing fronts grow at different rates.
            const minimum_core = @max(4, count * 35 / 100 / self.continent_count / 5);
            for (self.core_counts[0..self.continent_count]) |n| if (n < minimum_core) return error.TopologyConflict;
            // Reuse bounded heap scratch for a multi-source coast distance BFS.
            var read: usize = 0;
            var write: usize = 0;
            for (owners, 0..) |owner, i| {
                if (owner == 0) {
                    heap_ids[write] = @intCast(i);
                    write += 1;
                } else distances[i] = std.math.maxInt(u16);
            }
            while (read < write) : (read += 1) {
                const index = heap_ids[read];
                const x = index % mw;
                const y = index / mw;
                const neighbors = [_]?u32{ y * mw + (x + mw - 1) % mw, y * mw + (x + 1) % mw, if (y > 0) (y - 1) * mw + x else null, if (y + 1 < mh) (y + 1) * mw + x else null };
                for (neighbors) |possible| if (possible) |neighbor| {
                    if (distances[neighbor] == std.math.maxInt(u16)) {
                        distances[neighbor] = distances[index] + 1;
                        heap_ids[write] = neighbor;
                        write += 1;
                    }
                };
            }
        } // Release all growth/BFS scratch before retaining coast features.
        var accepted: usize = 0;
        for (0..2048) |attempt| {
            if (accepted == settings.island_count) break;
            const h = hash.mix(seed ^ hash.mix(attempt + 0x49534c414e44));
            const rx: u32 = @intCast(32 + h % 97);
            const ry: u32 = @intCast(32 + (h >> 8) % 97);
            const x: u32 = @intCast((h >> 16) % size[0]);
            const y: u32 = @intCast(160 + (h >> 40) % (size[1] - 320));
            if (!self.waterBox(x, y, rx + 24, ry + 24)) continue;
            var separate = true;
            for (self.islands[0..accepted]) |other| {
                if (@abs(hash.distanceX(x, other.x, size[0])) <= rx + other.radius_x + 24 and @abs(@as(i64, y) - other.y) <= ry + other.radius_y + 24) separate = false;
            }
            if (!separate) continue;
            self.islands[accepted] = .{ .id = @intCast(128 + accepted), .x = x, .y = y, .radius_x = rx, .radius_y = ry };
            accepted += 1;
        }
        if (accepted != settings.island_count) return error.RequiredFeaturePlacement;
        try self.prepareCoast(allocator);
        return self;
    }

    pub fn deinit(self: *Geography, allocator: std.mem.Allocator) void {
        self.coast_field.deinit(allocator);
        allocator.free(self.owners);
        allocator.free(self.coastal_distance);
    }

    fn waterBox(self: *const Geography, x: u32, y: u32, rx: u32, ry: u32) bool {
        if (y < ry or y + ry >= self.height) return false;
        const low_x = @divFloor(@as(i64, x) - rx, macro_size);
        const high_x = @divFloor(@as(i64, x) + rx, macro_size);
        var mx = low_x;
        while (mx <= high_x) : (mx += 1) for ((y - ry) / macro_size..(y + ry) / macro_size + 1) |my| {
            if (self.owners[my * self.macro_width + @as(usize, @intCast(@mod(mx, self.macro_width)))] != 0) return false;
        };
        return true;
    }

    fn ownerAt(self: *const Geography, mx: i64, my: i64) u8 {
        if (my < 0 or my >= self.macro_height) return 0;
        return self.owners[@as(usize, @intCast(my)) * self.macro_width + @as(usize, @intCast(@mod(mx, self.macro_width)))];
    }

    /// A full host proof: every possible feature column lies in an owned macro
    /// cell with no erodible coastal edge. No nine-point terrain inference.
    pub fn protectedBox(self: *const Geography, x: u32, y: u32, rx: u32, ry: u32, owner: u8) bool {
        if (y < ry or y + ry >= self.height) return false;
        var mx = @divFloor(@as(i64, x) - rx, 128);
        const max_x = @divFloor(@as(i64, x) + rx, 128);
        while (mx <= max_x) : (mx += 1) for ((y - ry) / 128..(y + ry) / 128 + 1) |my| {
            const index = my * self.macro_width + @as(usize, @intCast(@mod(mx, self.macro_width)));
            if (self.owners[index] != owner or self.coastal_distance[index] < 2) return false;
        };
        return true;
    }

    pub const Land = struct { id: u8 = 0, coast: u32 = 0 };

    pub fn landAt(self: *const Geography, x: i64, y: u32) Land {
        const cx = hash.wrappedX(x, self.width);
        const mx = cx / macro_size;
        const my = y / macro_size;
        const owner = self.ownerAt(mx, my);
        if (owner != 0) {
            const lx = cx % macro_size;
            const ly = y % macro_size;
            // Every occupied row is one interval containing the protected centre
            // spine. Adjacent owned cells share a wide face-centred bridge. Smooth
            // edge displacement only erodes a fringe and cannot cut either spine.
            const left = if (self.ownerAt(@as(i64, mx) - 1, my) == owner) @as(u32, 0) else self.trim(cx / 128 * 128, y);
            const right = if (self.ownerAt(@as(i64, mx) + 1, my) == owner) @as(u32, 0) else self.trim(cx / 128 * 128 + 127, y);
            const bottom = if (self.ownerAt(mx, @as(i64, my) - 1) == owner) @as(u32, 0) else self.trim(mx * 128 + 64, my * 128);
            const top = if (self.ownerAt(mx, @as(i64, my) + 1) == owner) @as(u32, 0) else self.trim(mx * 128 + 64, my * 128 + 127);
            if (ly >= bottom and ly + top < 128 and lx >= left and lx + right < 128) {
                return .{ .id = owner, .coast = self.coast_field.distance(cx, y) };
            }
        }
        for (self.islands[0..self.island_count]) |island| {
            const dy = @abs(@as(i64, y) - island.y);
            if (dy >= island.radius_y) continue;
            const v: i64 = @intCast(dy * 65536 / island.radius_y);
            const radius: u32 = @intCast(@max(1, @divTrunc(@as(i64, island.radius_x) * (65536 - @divTrunc(v * v, 65536)), 65536)));
            const dx: u32 = @intCast(@abs(hash.distanceX(cx, island.x, self.width)));
            if (dx <= radius) return .{ .id = island.id, .coast = radius - dx };
        }
        return .{};
    }

    fn trim(self: *const Geography, x: u32, y: u32) u32 {
        const n = hash.field2(hash.mix(self.seed ^ 0x434f415354), x % self.width, y, self.width, 256);
        return @intCast(8 + @divTrunc((n + 65535) * 16, 131070));
    }

    /// Explicit unfaded climate probe for terrain fixtures. Runtime queries use
    /// atWithClimate so the shared polar-boundary taper is always included.
    pub fn at(self: *const Geography, climate: env.ClimateId, x: i64, y: u32) env.ColumnEnvironment {
        return self.atSample(.{ .id = climate, .mountain_fade = if (climate == .frozen) 0 else 65535, .desert_terrain = if (climate == .desert) 65535 else 0 }, x, y);
    }

    pub fn atWithClimate(self: *const Geography, climate: env.ClimateField, x: i64, y: u32) env.ColumnEnvironment {
        return self.atSample(climate.sample(x, y), x, y);
    }

    fn atSample(self: *const Geography, sample: env.ClimateSample, x: i64, y: u32) env.ColumnEnvironment {
        const climate = sample.id;
        const cx = hash.wrappedX(x, self.width);
        const land = self.landAt(cx, y);
        var desert_biome: ?env.DesertBiome = null;
        const base_height: u32 = if (land.id != 0) land_height: {
            var elevation: i64 = undefined;
            if (sample.desert_terrain != 0) {
                const terrain = desert.sample(self.seed, cx, y, self.width);
                // Min preserves the field's slope bound, unlike multiplying
                // its height by a short coast ramp. Island radii can narrow
                // eight times faster along Y, so use a gentler island cap.
                const shore_cap = desert.unit + @divTrunc(@as(i64, land.coast) * desert.unit, if (land.id < 128) @as(i64, 4) else 32);
                const target = @min(terrain.elevation_q16, shore_cap);
                const blended = if (sample.desert_terrain == 65535) target else blend: {
                    const ordinary = self.rollingElevation(cx, y, land.coast) * desert.unit;
                    break :blend ordinary + @divTrunc((target - ordinary) * sample.desert_terrain, 65535);
                };
                // Quantize only after blending both desert biomes and shore.
                elevation = @divFloor(blended, desert.unit);
                if (climate == .desert) desert_biome = terrain.biome;
            } else {
                elevation = self.rollingElevation(cx, y, land.coast);
            }
            break :land_height @intCast(std.math.clamp(@as(i64, self.sea_level) + @max(1, elevation), 3, self.depth - 12));
        } else ocean_height: {
            const broad = hash.field2(hash.mix(self.seed ^ 0x5445525241494e), cx, y, self.width, @max(64, self.height / 16));
            break :ocean_height self.sea_level - @as(u32, @intCast(8 + @divTrunc((broad + 65535) * @as(i64, @min(140, self.sea_level / 2)), 131070)));
        };
        const mountain_sample = self.mountains.sample(land.id, cx, y, base_height, land.coast, sample.mountain_fade);
        const mountain = mountain_sample.strength;
        if (mountain != 0) desert_biome = null;
        // Low, gentle feet retain the local climate's cover. Higher flanks and
        // steep faces expose rock without querying four neighbouring columns.
        const exposed_rock = mountain_sample.shape_q16 >= 8192 or mountain_sample.grade_q16 >= 32768;
        const vegetation: env.VegetationId = if (land.id == 0 or climate == .frozen or climate == .desert)
            .barren
        else if (climate == .steppe)
            .sparse
        else if (hash.field2(hash.mix(self.seed ^ 0x4d4f495354555245), cx, y, self.width, @max(128, self.height / 20)) > 0)
            .forest
        else
            .meadow;
        return .{
            .climate = climate,
            .terrain_height = @max(3, mountain_sample.height),
            .sea_level = self.sea_level,
            .water_present = land.id == 0,
            .relief = if (mountain >= 18000) .mountain else .lowland,
            .mountain_strength = mountain,
            .desert_biome = desert_biome,
            .vegetation = vegetation,
            .geology = if (mountain >= 12000) .rocky else .sedimentary,
            .surface_cover = if (exposed_rock) .rock else if (climate == .desert) .sand else .soil,
            .landmass_id = land.id,
            .coast_distance = land.coast,
        };
    }

    fn rollingElevation(self: *const Geography, x: u32, y: u32, coast: u32) i64 {
        const broad = hash.field2(hash.mix(self.seed ^ 0x5445525241494e), x, y, self.width, @max(64, self.height / 16));
        const detail = hash.field2(hash.mix(self.seed ^ 0x44455441494c), x, y, self.width, 128);
        const land_height = 1 + @divTrunc((broad + 65535) * @as(i64, @min(48, self.depth / 16)), 131070);
        const coast_ramp: i64 = @intCast(@min(65535, @as(u64, coast) * 65535 / 96));
        return @divTrunc(land_height * coast_ramp, 65535) + @divTrunc(detail * 2 * coast_ramp, 65535 * 65535);
    }
};

/// A cardinal front has approximately 2*r*r cells. The offline-calibrated cost
/// scale makes 35% the nominal default-world coverage, with seed-dependent area.
/// Integer square root pins rounding across platforms; no coverage census runs.
fn growthHorizon(cells: usize, continents: u8) u32 {
    return std.math.sqrt(@as(u64, cells) * 35 * 98 * 98 / (200 * @as(u64, continents)));
}

const Heap = struct {
    ids: []u32,
    positions: []u32,
    costs: []u32,
    len: usize = 0,
    fn less(self: *const Heap, a: u32, b: u32) bool {
        return self.costs[a] < self.costs[b] or (self.costs[a] == self.costs[b] and a < b);
    }
    fn swap(self: *Heap, a: usize, b: usize) void {
        std.mem.swap(u32, &self.ids[a], &self.ids[b]);
        self.positions[self.ids[a]] = @intCast(a);
        self.positions[self.ids[b]] = @intCast(b);
    }
    fn insert(self: *Heap, id: u32) void {
        var pos: usize = self.positions[id];
        if (pos == std.math.maxInt(u32)) {
            pos = self.len;
            self.len += 1;
            self.ids[pos] = id;
            self.positions[id] = @intCast(pos);
        }
        while (pos > 0) {
            const parent = (pos - 1) / 2;
            if (!self.less(self.ids[pos], self.ids[parent])) break;
            self.swap(pos, parent);
            pos = parent;
        }
    }
    fn pop(self: *Heap) ?u32 {
        if (self.len == 0) return null;
        const id = self.ids[0];
        self.positions[id] = std.math.maxInt(u32) - 1;
        self.len -= 1;
        if (self.len != 0) {
            self.ids[0] = self.ids[self.len];
            self.positions[self.ids[0]] = 0;
            var pos: usize = 0;
            while (pos * 2 + 1 < self.len) {
                var child = pos * 2 + 1;
                if (child + 1 < self.len and self.less(self.ids[child + 1], self.ids[child])) child += 1;
                if (!self.less(self.ids[child], self.ids[pos])) break;
                self.swap(pos, child);
                pos = child;
            }
        }
        return id;
    }
};

test "mountain uplift fades at both polar boundaries in X and Y" {
    const allocator = std.testing.allocator;
    const owners = try allocator.alloc(u8, 512 * 256);
    defer allocator.free(owners);
    @memset(owners, 1);
    const coast = try allocator.alloc(u16, owners.len);
    defer allocator.free(coast);
    for (coast, 0..) |*distance, i| {
        const my = i / 512;
        distance.* = @intCast(@min(my + 1, 256 - my));
    }
    // A protected mainland isolates climate transitions from changing coastlines.
    var geography: Geography = .{ .seed = hash.stream(12345, .continents, 0), .width = 65536, .height = 32768, .depth = 1024, .sea_level = 384, .continent_count = 3, .island_count = 0, .macro_width = 512, .macro_height = 256, .owners = owners, .coastal_distance = coast };
    try geography.prepareCoast(allocator);
    defer geography.coast_field.deinit(allocator);
    geography.core_seeds[0] = .{ 65, 128 };
    const climate = env.ClimateField{ .seed = hash.stream(12345, .climate, 0), .width = geography.width, .height = geography.height, .displacement = (Settings{}).climateDisplacement(geography.height) };
    // Place known peaks across the taper instead of depending on procedural
    // range anchors intersecting the particular boundary rows in this fixture.
    geography.mountains = .{ .width = geography.width, .height = geography.height, .sea_level = geography.sea_level, .continent_count = 1 };
    const test_x = 11647;
    const test_boundaries = climate.boundaries(test_x);
    for ([_]u32{ test_boundaries[0] + 512, test_boundaries[5] - 513 }) |y| {
        geography.mountains.peaks[0][geography.mountains.binAt(y)] = .{
            .active = true,
            .center = .{ test_x, y },
            .summit_height = 973,
            .radii_x = .{ 2048, 1536 },
            .radii_y = .{ 1800, 1800 },
        };
    }
    geography.mountains.rebuildIndex();
    var tapered_columns: usize = 0;
    for (0..1024) |i| {
        const x: i64 = @intCast(i * 64);
        const boundaries = climate.boundaries(x);
        for ([_]u32{ boundaries[0], boundaries[5] }) |boundary| {
            const south = geography.atWithClimate(climate, x, boundary - 1);
            const north = geography.atWithClimate(climate, x, boundary);
            try std.testing.expectEqual(@as(u16, 0), south.mountain_strength);
            try std.testing.expectEqual(@as(u16, 0), north.mountain_strength);
            try std.testing.expect(@abs(@as(i64, south.terrain_height) - north.terrain_height) <= 1);
            for ([_]u32{ boundary - 1, boundary }) |y| {
                const a = geography.atWithClimate(climate, x, y);
                const b = geography.atWithClimate(climate, x + 1, y);
                try std.testing.expect(@abs(@as(i64, a.terrain_height) - b.terrain_height) <= 2);
                try std.testing.expectEqualDeep(a, geography.atWithClimate(climate, x - geography.width, y));
            }
        }
        for ([_]u32{ boundaries[0] + 512, boundaries[5] - 513 }) |y| {
            const tapered = geography.atWithClimate(climate, x, y);
            const untapered = geography.at(climate.at(x, y), x, y);
            if (untapered.mountain_strength > 0) {
                tapered_columns += 1;
                try std.testing.expect(tapered.mountain_strength < untapered.mountain_strength);
            }
        }
    }
    try std.testing.expect(tapered_columns > 0);

    // Keep the reported frozen/steppe cliff on protected inland terrain even
    // when a different continent-growth version moves its historical shore.
    const boundary = climate.boundaries(11647)[0];
    const frozen = geography.atWithClimate(climate, 11647, boundary - 1);
    const steppe = geography.atWithClimate(climate, 11647, boundary);
    try std.testing.expectEqual(env.ClimateId.frozen, frozen.climate);
    try std.testing.expectEqual(env.ClimateId.steppe, steppe.climate);
    try std.testing.expectEqual(@as(u8, 1), frozen.landmass_id);
    try std.testing.expectEqual(frozen.landmass_id, steppe.landmass_id);
    try std.testing.expect(frozen.coast_distance > 128 and steppe.coast_distance > 128);
    try std.testing.expectEqual(@as(u16, 0), frozen.mountain_strength);
    try std.testing.expectEqual(@as(u16, 0), steppe.mountain_strength);
    try std.testing.expect(@abs(@as(i64, frozen.terrain_height) - steppe.terrain_height) <= 1);
}

test "internal macro joins and wrapped mainland joins have no height cliff" {
    for (0..2) |fixture| {
        var owners = [_]u8{0} ** 64;
        var coarse = [_]u16{0} ** 64;
        for (2..6) |y| for (0..4) |column| {
            const x = (column + (if (fixture == 0) @as(usize, 2) else 6)) % 8;
            owners[y * 8 + x] = 1;
            coarse[y * 8 + x] = @intCast(@min(column + 1, 4 - column, y - 1, 6 - y));
        };
        // Freeze the ownership shape: this coast/relief regression must continue
        // sampling mainland when continent-growth tuning changes seeded maps.
        var geography = Geography{ .seed = hash.stream(12345, .continents, 0), .width = 1024, .height = 1024, .depth = 128, .sea_level = 48, .continent_count = 1, .island_count = 0, .macro_width = 8, .macro_height = 8, .owners = &owners, .coastal_distance = &coarse };
        geography.core_seeds[0] = .{ if (fixture == 0) 3 else 7, 3 };
        try geography.prepareCoast(std.testing.allocator);
        defer geography.coast_field.deinit(std.testing.allocator);
        const x: u32 = if (fixture == 0) 511 else 1023;
        const west = geography.at(.temperate, x, 448);
        const east = geography.at(.temperate, @as(i64, x) + 1, 448);
        try std.testing.expectEqual(@as(u8, 1), west.landmass_id);
        try std.testing.expectEqual(west.landmass_id, east.landmass_id);
        try std.testing.expect(@abs(@as(i64, west.coast_distance) - east.coast_distance) <= 2);
        try std.testing.expect(@abs(@as(i64, west.terrain_height) - east.terrain_height) <= 2);
    }
}

test "growth horizon uses bounded integer square root at supported grid sizes" {
    for ([_]usize{ 256, 131072, 1048576 }) |cells| for ([_]u8{ 3, 4, 5 }) |continents| {
        const squared = @as(u64, cells) * 35 * 98 * 98 / (200 * @as(u64, continents));
        const horizon: u64 = growthHorizon(cells, continents);
        try std.testing.expect(horizon * horizon <= squared);
        try std.testing.expect((horizon + 1) * (horizon + 1) > squared);
    };
}

test "cost limited continents are deterministic connected separated and vary in area" {
    var areas: [2]u32 = @splat(0);
    for ([_]u64{ 12345, 0 }, 0..) |seed, sample| {
        const stream = hash.stream(seed, .continents, 0);
        var first = try Geography.init(std.testing.allocator, stream, .{ 2048, 2048, 128 }, .{ .island_count = 1 });
        defer first.deinit(std.testing.allocator);
        var again = try Geography.init(std.testing.allocator, stream, .{ 2048, 2048, 128 }, .{ .island_count = 1 });
        defer again.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, first.owners, again.owners);
        try std.testing.expectEqualSlices(u16, first.coastal_distance, again.coastal_distance);
        try std.testing.expectEqualDeep(first.core_counts, again.core_counts);
        try std.testing.expectEqualDeep(first.islands[0], again.islands[0]);
        const mw = first.macro_width;
        const mh = first.macro_height;
        for (first.owners, 0..) |owner, i| {
            if (owner == 0) continue;
            areas[sample] += 1;
            const x: i64 = @intCast(i % mw);
            const y: i64 = @intCast(i / mw);
            try std.testing.expect(y > 0 and y + 1 < mh);
            for (0..3) |oy| for (0..3) |ox| {
                const neighbor = first.ownerAt(x + @as(i64, @intCast(ox)) - 1, y + @as(i64, @intCast(oy)) - 1);
                try std.testing.expect(neighbor == 0 or neighbor == owner);
            };
        }
        // An independent cardinal graph walk checks each owner reaches its root.
        for (first.core_seeds[0..first.continent_count], 0..) |root, owner_index| {
            var visited = [_]bool{false} ** 256;
            var queue: [256]u32 = undefined;
            const start = root[1] * mw + root[0];
            queue[0] = start;
            visited[start] = true;
            var read: usize = 0;
            var count: usize = 1;
            while (read < count) : (read += 1) {
                const index = queue[read];
                const x = index % mw;
                const y = index / mw;
                for ([_]?u32{ y * mw + (x + mw - 1) % mw, y * mw + (x + 1) % mw, if (y > 0) index - mw else null, if (y + 1 < mh) index + mw else null }) |possible| {
                    const next = possible orelse continue;
                    if (visited[next] or first.owners[next] != owner_index + 1) continue;
                    visited[next] = true;
                    queue[count] = next;
                    count += 1;
                }
            }
            try std.testing.expectEqual(first.core_counts[owner_index], count);
        }
    }
    try std.testing.expect(areas[0] != areas[1]);
}

test "approximate mainland coast has bounded shore error and gradients at corners necks and seam" {
    const a = std.testing.allocator;
    const w = 512;
    const h = 512;
    const n = w * h;
    const owners = try a.alloc(u8, 16);
    defer a.free(owners);
    const coarse = try a.alloc(u16, 16);
    defer a.free(coarse);
    const queue = try a.alloc(u32, n);
    defer a.free(queue);
    const exact = try a.alloc(u16, n);
    defer a.free(exact);
    const output = try a.alloc(u16, n);
    defer a.free(output);
    var checked: usize = 0;
    var collar: usize = 0;
    var maximum_height_delta: u32 = 0;
    for (0..4) |fixture| {
        @memset(owners, 0);
        switch (fixture) {
            0 => {
                owners[5] = 1;
                owners[6] = 1;
                owners[9] = 1;
                owners[10] = 1;
            },
            1 => {
                owners[4] = 1;
                owners[7] = 1;
                owners[8] = 1;
                owners[9] = 1;
                owners[11] = 1;
            },
            2 => {
                owners[4] = 1;
                owners[5] = 1;
                owners[6] = 1;
                owners[9] = 1;
                owners[10] = 1;
            },
            else => {
                owners[4] = 1;
                owners[5] = 1;
                owners[6] = 1;
                owners[7] = 1;
                owners[8] = 1;
                owners[11] = 1;
            },
        }
        // Exact macro Manhattan distance from every water cell, finite Y/periodic X.
        var read: usize = 0;
        var write: usize = 0;
        for (owners, 0..) |owner, i| {
            coarse[i] = if (owner == 0) 0 else 65535;
            if (owner == 0) {
                queue[write] = @intCast(i);
                write += 1;
            }
        }
        while (read < write) : (read += 1) {
            const i = queue[read];
            const x = i % 4;
            const y = i / 4;
            for ([_]?u32{ y * 4 + (x + 3) % 4, y * 4 + (x + 1) % 4, if (y > 0) i - 4 else null, if (y < 3) i + 4 else null }) |possible| if (possible) |j| {
                if (coarse[j] == 65535) {
                    coarse[j] = coarse[i] + 1;
                    queue[write] = j;
                    write += 1;
                }
            };
        }
        var g = Geography{ .seed = hash.mix(12345 + fixture), .width = w, .height = h, .depth = 128, .sea_level = 48, .continent_count = 1, .island_count = 0, .macro_width = 4, .macro_height = 4, .owners = owners, .coastal_distance = coarse };
        g.core_seeds[0] = .{ 1, 1 };
        var field = try CoastApprox.init(a, g.seed, w, h, owners, coarse);
        defer field.deinit(a);
        g.coast_field = field;
        for (0..2) |maximal| {
            if (maximal == 1) for (field.features) |*feature| {
                if (feature.* != 0) feature.* = (feature.* & 15) | (24 << 4);
            };
            read = 0;
            write = 0;
            // Seed an independent fine-grid distance BFS from the production
            // refined footprint; this checks proximity, not footprint topology.
            for (0..h) |y| for (0..w) |x| {
                const i = y * w + x;
                if (g.landAt(@intCast(x), @intCast(y)).id == 0) {
                    exact[i] = 0;
                    queue[write] = @intCast(i);
                    write += 1;
                } else exact[i] = 65535;
            };
            while (read < write) : (read += 1) {
                const i = queue[read];
                const x = i % w;
                const y = i / w;
                for (0..3) |oy| for (0..3) |ox| {
                    const ny = @as(i64, y) + @as(i64, @intCast(oy)) - 1;
                    if (ny < 0 or ny >= h) continue;
                    const nx: usize = @intCast(@mod(@as(i64, x) + @as(i64, @intCast(ox)) - 1, w));
                    const j = @as(usize, @intCast(ny)) * w + nx;
                    if (exact[j] == 65535) {
                        exact[j] = exact[i] + 1;
                        queue[write] = @intCast(j);
                        write += 1;
                    }
                };
            }
            for (0..h) |y| for (0..w) |x| {
                const land = g.landAt(@intCast(x), @intCast(y));
                const i = y * w + x;
                try std.testing.expectEqual(exact[i] > 0, land.id != 0);
                output[i] = @intCast(land.coast);
                if (land.id == 0) continue;
                checked += 1;
                const sample = field.sample(@intCast(x), @intCast(y));
                const actual = exact[i] - 1;
                const capped = @min(128, actual);
                try std.testing.expect(sample.local <= capped and sample.local + 16 >= capped);
                try std.testing.expectEqual(sample.local == 0, sample.coast == 0);
                if (actual == 0) try std.testing.expectEqual(@as(u32, 0), sample.coast);
                if (sample.coast == 0) {
                    collar += 1;
                    try std.testing.expect(actual <= 16);
                }
            };
            for (0..h) |y| for (0..w) |x| {
                const i = y * w + x;
                for ([_]?usize{ y * w + (x + 1) % w, if (y + 1 < h) i + w else null }) |possible| if (possible) |j| {
                    try std.testing.expect(@abs(@as(i64, output[i]) - output[j]) <= 2);
                    if (exact[i] == 0 or exact[j] == 0) continue;
                    const aa = g.at(.temperate, @intCast(x), @intCast(y));
                    const bb = g.at(.temperate, @intCast(j % w), @intCast(j / w));
                    const delta: u32 = @intCast(@abs(@as(i64, aa.terrain_height) - bb.terrain_height));
                    maximum_height_delta = @max(maximum_height_delta, delta);
                    try std.testing.expect(delta <= 8);
                };
            };
        }
    }
    std.debug.print("approx adversarial mainland columns={d} flat-collar columns={d} maximum adjacent-land height delta={d}\n", .{ checked, collar, maximum_height_delta });
}

test "shared bilinear coast extension has bounded interior and capped gradients" {
    const a = std.testing.allocator;
    const w = 8192;
    const h = 12288;
    const mw = w / 128;
    const mh = h / 128;
    const n = mw * mh;
    const owners = try a.alloc(u8, n);
    defer a.free(owners);
    const coarse = try a.alloc(u16, n);
    defer a.free(coarse);
    for (0..mh) |y| for (0..mw) |x| {
        const d = @min(y, mh - 1 - y);
        owners[y * mw + x] = if (d == 0) 0 else 1;
        coarse[y * mw + x] = @intCast(d);
    };
    var field = try CoastApprox.init(a, 12345, w, h, owners, coarse);
    defer field.deinit(a);
    var capped_columns: usize = 0;
    for (0..h) |y| for ([_]u32{ 0, 1, 127, 128, 4095, 8191 }) |x| {
        if (owners[(y / 128) * mw + x / 128] == 0) continue;
        const value = field.sample(x, @intCast(y));
        capped_columns += @intFromBool(value.coast == CoastApprox.cap);
        const right = field.sample((x + 1) % w, @intCast(y));
        try std.testing.expect(@abs(@as(i64, value.coast) - right.coast) <= 2);
        if (y + 1 < h and owners[((y + 1) / 128) * mw + x / 128] != 0) {
            const top = field.sample(x, @intCast(y + 1));
            try std.testing.expect(@abs(@as(i64, value.coast) - top.coast) <= 2);
        }
    };
    try std.testing.expect(capped_columns > 0);
}

test "gentle mountain feet retain climate cover and upper faces expose stone" {
    var owners = [_]u8{1} ** 64;
    var coasts = [_]u16{6} ** 64;
    var g = Geography{ .seed = 12345, .width = 1024, .height = 1024, .depth = 1024, .sea_level = 512, .continent_count = 1, .island_count = 0, .macro_width = 8, .macro_height = 8, .owners = &owners, .coastal_distance = &coasts };
    try g.prepareCoast(std.testing.allocator);
    defer g.coast_field.deinit(std.testing.allocator);
    g.mountains = .{ .width = g.width, .height = g.height, .sea_level = g.sea_level, .continent_count = 1 };
    g.mountains.peaks[0][16] = .{ .active = true, .center = .{ 512, 512 }, .summit_height = 972, .radii_x = .{ 400, 400 }, .radii_y = .{ 48, 48 }, .shape_x = .{ 4, 12 }, .shape_y = .{ 4, 4 } };
    g.mountains.rebuildIndex();
    for ([_]env.ClimateId{ .temperate, .steppe, .desert }) |climate| {
        const foot = g.at(climate, 850, 512);
        try std.testing.expect(foot.mountain_strength > 0);
        try std.testing.expectEqual(if (climate == .desert) env.SurfaceCover.sand else .soil, foot.surface_cover);
        const summit = g.at(climate, 512, 512);
        try std.testing.expectEqual(@as(u32, 972), summit.terrain_height);
        try std.testing.expectEqual(env.SurfaceCover.rock, summit.surface_cover);
        try std.testing.expectEqual(env.ReliefId.mountain, summit.relief);
    }
    const frozen = g.at(.frozen, 512, 512);
    try std.testing.expectEqual(@as(u16, 0), frozen.mountain_strength);
    try std.testing.expectEqual(env.SurfaceCover.soil, frozen.surface_cover);
}
