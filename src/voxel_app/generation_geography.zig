const std = @import("std");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");
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
    core_seeds: [5][2]u32 = undefined,
    core_counts: [5]u32 = @splat(0),

    pub const InitError = error{ OutOfMemory, TopologyConflict, RequiredFeaturePlacement };

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
        return self;
    }

    pub fn deinit(self: *Geography, allocator: std.mem.Allocator) void {
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
                const d = self.coastal_distance[my * self.macro_width + mx];
                return .{ .id = owner, .coast = if (d > 1) (@as(u32, d) - 1) * 128 + 16 else @min(@min(lx - left, 127 - lx - right), @min(ly - bottom, 127 - ly - top)) };
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
    pub fn at(self: *const Geography, climate: env.ClimateId, x: i64, y: u32) env.ColumnEnvironment {
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
                mountain = @intCast(@as(u64, @intCast(amplitude)) * fade / 65535 * coast_fade / 65535);
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
