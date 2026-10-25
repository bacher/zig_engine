const std = @import("std");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");
const CoastApprox = @import("generation_coast_approx.zig").CoastApprox;
const Settings = @import("generation_settings.zig").NaturalSettings;

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
        return @as(u64, cells) * (128 + CoastApprox.build_probe_bound_per_cell);
    }

    /// Explicit fixture entry point. Call once after the ownership and macro
    /// distance arrays are final; init prepares this before returning a world.
    pub fn prepareCoast(self: *Geography, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        self.coast_field = try CoastApprox.init(allocator, self.seed, self.width, self.height, self.owners, self.coastal_distance);
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
        var self = Geography{ .seed = seed, .width = size[0], .height = size[1], .depth = size[2], .sea_level = @intCast(@as(u64, size[2]) * 3 / 8), .continent_count = @intCast(3 + hash.mix(seed) % 3), .island_count = settings.island_count, .macro_width = mw, .macro_height = mh, .owners = owners, .coastal_distance = distances };
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
                costs[index] = @intCast((h >> 32) % 200);
                heap.insert(index);
            }
            var filled: usize = 0;
            // Coast erosion removes a bounded fringe; this coarse target is tuned
            // offline, never followed by a fine-resolution acceptance census.
            const target = count * 61 / 100;
            while (heap.pop()) |index| {
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
                filled += 1;
                if (filled == target) break;
                const neighbors = [_]u32{ y * mw + (x + mw - 1) % mw, y * mw + (x + 1) % mw, (y - 1) * mw + x, (y + 1) * mw + x };
                for (neighbors) |neighbor| {
                    if (owners[neighbor] != 0 or heap.positions[neighbor] == std.math.maxInt(u32) - 1) continue;
                    const nx = neighbor % mw;
                    const ny = neighbor / mw;
                    const field = hash.field2(hash.mix(seed ^ 0x47524f575448), nx * 128, ny * 128, size[0], @max(256, size[1] / 12));
                    const edge: u32 = @intCast(40 + @divTrunc((field + 65535) * 100, 131070) + @as(i64, @intCast(hash.at(seed, nx, ny) % 35)));
                    const next = costs[index] + edge;
                    if (next < costs[neighbor] or (next == costs[neighbor] and owner < pending[neighbor])) {
                        costs[neighbor] = next;
                        pending[neighbor] = owner;
                        heap.insert(neighbor);
                    }
                }
            }
            if (filled < target) return error.TopologyConflict;
            for (self.core_counts[0..self.continent_count]) |n| if (n < @max(4, target / self.continent_count / 5)) return error.TopologyConflict;
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

    fn centre(self: *const Geography, id: u8, y: u32) i64 {
        const core = self.core_seeds[id];
        const phase = hash.wrappedX(@as(i64, y) + @as(i64, @intCast(hash.mix(self.seed +% id) % self.height)), self.height);
        const winding = hash.periodic(hash.mix(self.seed +% id), phase, self.height, 3);
        return @as(i64, core[0]) * 128 + 64 + @divTrunc(winding * @as(i64, self.width / self.continent_count), 65536 * 10);
    }
    /// Explicit unfaded climate probe for terrain fixtures. Runtime queries use
    /// atWithClimate so the shared polar-boundary taper is always included.
    pub fn at(self: *const Geography, climate: env.ClimateId, x: i64, y: u32) env.ColumnEnvironment {
        return self.atSample(.{ .id = climate, .mountain_fade = if (climate == .frozen) 0 else 65535 }, x, y);
    }

    pub fn atWithClimate(self: *const Geography, climate: env.ClimateField, x: i64, y: u32) env.ColumnEnvironment {
        return self.atSample(climate.sample(x, y), x, y);
    }

    fn atSample(self: *const Geography, sample: env.ClimateSample, x: i64, y: u32) env.ColumnEnvironment {
        const climate = sample.id;
        const cx = hash.wrappedX(x, self.width);
        const land = self.landAt(cx, y);
        var mountain: u16 = 0;
        if (land.id > 0 and land.id < 128 and climate != .frozen and land.coast > 16) {
            const id = land.id - 1;
            const radius: i64 = @intCast(@max(12, @min(900, self.width / self.continent_count / 12)));
            const ridge_x = self.centre(id, y) + @as(i64, @intCast(self.width / self.continent_count / 7));
            const dx: i64 = @intCast(@abs(hash.distanceX(cx, ridge_x, self.width)));
            const ridge_seed = hash.mix(self.seed +% id +% 0x5249444745);
            const ridge_y_start = self.height / 20 + @as(u32, @intCast(ridge_seed % @max(1, self.height / 6)));
            const ridge_y_end = self.height - self.height / 20 - @as(u32, @intCast((ridge_seed >> 24) % @max(1, self.height / 6)));
            if (dx < radius and y > ridge_y_start and y < ridge_y_end) {
                const edge = @min(y - ridge_y_start, ridge_y_end - y);
                const fade = @min(65535, @as(u64, edge) * 65535 / @max(1, self.height / 12));
                const coast_fade = @min(65535, @as(u64, land.coast - 16) * 65535 / @max(1, @as(u64, @intCast(radius))));
                const amplitude = @divTrunc((radius - dx) * 65535, radius);
                mountain = @intCast(@as(u64, @intCast(amplitude)) * fade / 65535 * coast_fade / 65535 * sample.mountain_fade / 65535);
            }
        }
        const broad = hash.field2(hash.mix(self.seed ^ 0x5445525241494e), cx, y, self.width, @max(64, self.height / 16));
        const detail = hash.field2(hash.mix(self.seed ^ 0x44455441494c), cx, y, self.width, 128);
        const land_height = 1 + @divTrunc((broad + 65535) * @as(i64, @min(48, self.depth / 16)), 131070);
        const coast_ramp: i64 = @intCast(@min(65535, @as(u64, land.coast) * 65535 / 96));
        const uplift = @divTrunc(@as(i64, mountain) * @as(i64, @min(320, self.depth / 3)), 65535);
        const elevation = @divTrunc(land_height * coast_ramp, 65535) + uplift + @divTrunc(detail * 2 * coast_ramp, 65535 * 65535);
        const height: u32 = if (land.id != 0)
            @intCast(std.math.clamp(@as(i64, self.sea_level) + @max(1, elevation), 3, self.depth - 12))
        else
            self.sea_level - @as(u32, @intCast(8 + @divTrunc((broad + 65535) * @as(i64, @min(140, self.sea_level / 2)), 131070)));
        const moisture = hash.field2(hash.mix(self.seed ^ 0x4d4f495354555245), cx, y, self.width, @max(128, self.height / 20));
        const vegetation: env.VegetationId = if (land.id == 0 or climate == .frozen or climate == .desert)
            .barren
        else if (climate == .steppe)
            .sparse
        else if (moisture > 0)
            .forest
        else
            .meadow;
        return .{
            .climate = climate,
            .terrain_height = @max(3, height),
            .sea_level = self.sea_level,
            .water_present = land.id == 0,
            .relief = if (mountain >= 18000) .mountain else .lowland,
            .mountain_strength = mountain,
            .vegetation = vegetation,
            .geology = if (mountain >= 12000) .rocky else .sedimentary,
            .surface_cover = if (climate == .desert) .sand else if (mountain >= 36000) .rock else .soil,
            .landmass_id = land.id,
            .coast_distance = land.coast,
        };
    }

    pub fn mainlandCentre(self: *const Geography, id: u8, y: u32) u32 {
        return hash.wrappedX(self.centre(id, y), self.width);
    }
};

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

test "ridge uplift fades at both polar boundaries in X and Y" {
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
}

test "default frozen-steppe ridge join has no height cliff" {
    var geography = try Geography.init(std.testing.allocator, hash.stream(12345, .continents, 0), .{ 65536, 32768, 1024 }, .{});
    defer geography.deinit(std.testing.allocator);
    const climate = env.ClimateField{ .seed = hash.stream(12345, .climate, 0), .width = geography.width, .height = geography.height, .displacement = (Settings{}).climateDisplacement(geography.height) };
    const boundary = climate.boundaries(11647)[0];
    const frozen = geography.atWithClimate(climate, 11647, boundary - 1);
    const steppe = geography.atWithClimate(climate, 11647, boundary);
    try std.testing.expectEqual(env.ClimateId.frozen, frozen.climate);
    try std.testing.expectEqual(env.ClimateId.steppe, steppe.climate);
    try std.testing.expectEqual(@as(u16, 0), frozen.mountain_strength);
    try std.testing.expectEqual(@as(u16, 0), steppe.mountain_strength);
    try std.testing.expectEqual(frozen.landmass_id, steppe.landmass_id);
    try std.testing.expect(@abs(@as(i64, frozen.terrain_height) - steppe.terrain_height) <= 1);
}

test "reported internal macro join has no mainland height cliff" {
    var geography = try Geography.init(std.testing.allocator, hash.stream(12345, .continents, 0), .{ 65536, 32768, 1024 }, .{});
    defer geography.deinit(std.testing.allocator);
    const climate = env.ClimateField{ .seed = hash.stream(12345, .climate, 0), .width = geography.width, .height = geography.height, .displacement = (Settings{}).climateDisplacement(geography.height) };
    const west = geography.atWithClimate(climate, 36735, 13632);
    const east = geography.atWithClimate(climate, 36736, 13632);
    try std.testing.expect(west.landmass_id > 0 and west.landmass_id < 128);
    try std.testing.expectEqual(west.landmass_id, east.landmass_id);
    try std.testing.expect(@abs(@as(i64, west.coast_distance) - east.coast_distance) <= 2);
    try std.testing.expect(@abs(@as(i64, west.terrain_height) - east.terrain_height) <= 2);
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
