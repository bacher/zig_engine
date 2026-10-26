const std = @import("std");
const BlockType = @import("engine").voxel_chunk.BlockType;
const hash = @import("generation_hash.zig");
const Settings = @import("generation_settings.zig").NaturalSettings;

pub const ResourceId = enum(u8) { metal_ore, limestone, clay, coal, sand };
pub const SizeClass = enum(u8) { large, small, starter };
pub const ResourceDefinition = struct { resource: ResourceId, block: BlockType, priority: u8, large_radii: [3]u32, has_small: bool };
pub const definitions = [_]ResourceDefinition{
    .{ .resource = .metal_ore, .block = .metal_ore, .priority = 0, .large_radii = .{ 96, 384, 12 }, .has_small = false },
    .{ .resource = .limestone, .block = .limestone, .priority = 1, .large_radii = .{ 192, 768, 12 }, .has_small = false },
    .{ .resource = .clay, .block = .clay, .priority = 2, .large_radii = .{ 96, 256, 4 }, .has_small = true },
    .{ .resource = .coal, .block = .coal, .priority = 3, .large_radii = .{ 96, 384, 4 }, .has_small = true },
    .{ .resource = .sand, .block = .sand, .priority = 4, .large_radii = .{ 192, 384, 8 }, .has_small = true },
};

pub const Deposit = struct {
    id: u16,
    resource: ResourceId,
    size_class: SizeClass,
    center: [3]u32,
    radii: [3]u32,
    priority: u8,
    /// A conservative contained solid cuboid, after all clipping/overlap checks.
    minimum_effective_blocks: u32,
    effective_blocks: u64 = 0,

    pub fn contains(self: Deposit, x: i64, y: u32, z: u32, width: u32) bool {
        const dx = @abs(hash.distanceX(x, self.center[0], width));
        const dy = @abs(@as(i64, y) - self.center[1]);
        const dz = @abs(@as(i64, z) - self.center[2]);
        if (dx > self.radii[0] or dy > self.radii[1] or dz > self.radii[2]) return false;
        return dx * dx * 65536 / (@as(u64, self.radii[0]) * self.radii[0]) + dy * dy * 65536 / (@as(u64, self.radii[1]) * self.radii[1]) + dz * dz * 65536 / (@as(u64, self.radii[2]) * self.radii[2]) <= 65536;
    }
};

pub const Deposits = struct {
    pub const max_deposits = 5 * 16 + 3 * 24 + 3;
    items: [max_deposits]Deposit = undefined,
    count: u16 = 0,
    /// Eight-by-eight fixed coarse buckets cover complete ellipsoid bounds.
    bins: [64][256]u8 = undefined,
    bin_counts: [64]u16 = @splat(0),
    references: u32 = 0,
    maximum_bin_occupancy: u16 = 0,
    width: u32,
    height: u32,

    pub const InitError = error{ RequiredFeaturePlacement, FeatureIndexCapacity, DepositValidity, StartAccessUnavailable };

    pub fn init(world: anytype, seed: u64, settings: Settings) InitError!Deposits {
        var observed: u64 = 0;
        return initObserved(world, seed, settings, &observed);
    }

    pub fn initObserved(world: anytype, seed: u64, settings: Settings, observed: *u64) InitError!Deposits {
        var self = Deposits{ .width = world.layout.size_in_blocks[0], .height = world.layout.size_in_blocks[1] };
        for (definitions) |definition| {
            for (0..settings.large_deposits_per_resource) |i| {
                const deposit = self.place(world, seed, definition, .large, @intCast(i)) orelse return error.RequiredFeaturePlacement;
                self.items[self.count] = deposit;
                self.count += 1;
            }
            if (definition.has_small) for (0..settings.small_deposits_per_resource) |i| {
                const deposit = self.place(world, seed, definition, .small, @intCast(i)) orelse return error.RequiredFeaturePlacement;
                self.items[self.count] = deposit;
                self.count += 1;
            };
        }
        // Three shallow, physically connected access patches at the first start.
        // Their entire dry path is checked column-by-column before vegetation.
        for ([_]ResourceId{ .clay, .sand, .coal }, 0..) |resource, i| {
            const offset = ([_][2]i32{ .{ 24, 0 }, .{ -24, 0 }, .{ 0, 24 } })[i];
            const sx = world.first_start[0];
            const sy = world.first_start[1];
            const x = hash.wrappedX(@as(i64, sx) + offset[0], self.width);
            const y: u32 = @intCast(@as(i64, sy) + offset[1]);
            const e = world.baseEnvironmentAt(x, y);
            if (e.water_present or e.relief == .mountain or e.terrain_height < 12) return error.StartAccessUnavailable;
            var previous = world.first_start[2];
            for (0..25) |step| {
                const px = hash.wrappedX(@as(i64, sx) + @divTrunc(@as(i64, offset[0]) * @as(i64, @intCast(step)), 24), self.width);
                const py: u32 = @intCast(@as(i64, sy) + @divTrunc(@as(i64, offset[1]) * @as(i64, @intCast(step)), 24));
                const route = world.baseEnvironmentAt(px, py);
                if (route.water_present or route.landmass_id != e.landmass_id or @abs(@as(i64, route.terrain_height) - previous) > 1) return error.StartAccessUnavailable;
                previous = route.terrain_height;
            }
            var d = Deposit{ .id = self.count, .resource = resource, .size_class = .starter, .center = .{ x, y, e.terrain_height - 4 }, .radii = .{ 5, 5, 1 }, .priority = 0, .minimum_effective_blocks = 0 };
            if (!self.disjoint(d)) return error.DepositValidity;
            d.effective_blocks = effectiveCount(world, d, false) orelse return error.DepositValidity;
            d.minimum_effective_blocks = @intCast(d.effective_blocks);
            self.items[self.count] = d;
            self.count += 1;
        }
        for (self.items[0..self.count], 0..) |deposit, index| {
            const min_y = (deposit.center[1] - deposit.radii[1]) * 8 / self.height;
            const max_y: u32 = @min(7, (deposit.center[1] + deposit.radii[1]) * 8 / self.height);
            for (min_y..max_y + 1) |by| for (0..8) |bx| {
                // A bucket intersects the wrapped horizontal bounding interval.
                const low = @as(u64, bx) * self.width / 8;
                const high = @as(u64, bx + 1) * self.width / 8 - 1;
                const mid: i64 = @intCast((low + high) / 2);
                if (@abs(hash.distanceX(mid, deposit.center[0], self.width)) > deposit.radii[0] + (high - low + 1) / 2 + 1) continue;
                const bin = by * 8 + bx;
                const n = self.bin_counts[bin];
                if (n >= settings.feature_index_capacity) {
                    observed.* = @as(u64, n) + 1;
                    return error.FeatureIndexCapacity;
                }
                self.bins[bin][n] = @intCast(index);
                self.bin_counts[bin] += 1;
                self.references += 1;
                self.maximum_bin_occupancy = @max(self.maximum_bin_occupancy, n + 1);
            };
        }
        return self;
    }

    fn place(self: *const Deposits, world: anytype, seed: u64, definition: ResourceDefinition, size_class: SizeClass, serial: u16) ?Deposit {
        for (0..256) |attempt| {
            const h = hash.mix(seed ^ (@as(u64, @intFromEnum(definition.resource)) << 48) ^ (@as(u64, @intFromEnum(size_class)) << 40) ^ (@as(u64, serial) << 16) ^ attempt);
            const macro = h % world.geography.owners.len;
            var owner = world.geography.owners[macro];
            var y: u32 = @intCast(macro / world.geography.macro_width * 128 + 64);
            var x: u32 = @intCast(macro % world.geography.macro_width * 128 + 64);
            var metal_extent: [2]u32 = .{ std.math.maxInt(u32), std.math.maxInt(u32) };
            if (definition.resource == .metal_ore) {
                // Follow the retained range hosts rather than reconstructing a
                // ridge axis. Small offsets allow several disjoint large bodies
                // in broad peaks while every footprint still proves its host.
                const peak_owner = h % world.geography.continent_count;
                const peak_bin = (h >> 16) % @import("generation_mountains.zig").bin_count;
                const peak = world.geography.mountains.peaks[peak_owner][peak_bin];
                if (!peak.active) continue;
                owner = @intCast(peak_owner + 1);
                metal_extent = .{ @min(peak.radii_x[0], peak.radii_x[1]) / 4, @min(peak.radii_y[0], peak.radii_y[1]) / 4 };
                const dx = @as(i64, @intCast((h >> 24) % @max(1, metal_extent[0]))) - @as(i64, metal_extent[0] / 2);
                const dy = @as(i64, @intCast((h >> 40) % @max(1, metal_extent[1]))) - @as(i64, metal_extent[1] / 2);
                x = hash.wrappedX(@as(i64, peak.center[0]) + dx, self.width);
                const candidate_y = @as(i64, peak.center[1]) + dy;
                if (candidate_y < 0 or candidate_y >= self.height) continue;
                y = @intCast(candidate_y);
            }
            if (owner == 0) continue;
            const e = world.baseEnvironmentAt(x, y);
            if (e.landmass_id != owner or e.water_present or e.coast_distance < 80) continue;
            if (definition.resource == .metal_ore and e.relief != .mountain) continue;
            if (definition.resource != .metal_ore and e.geology != .sedimentary) continue;
            if (size_class != .large and e.surface_cover == .sand) continue;
            const cover: u32 = if (size_class == .large) 12 else 4;
            const available = @max(8, e.coast_distance / 3);
            const radii: [3]u32 = if (size_class == .large)
                .{ @max(16, @min(definition.large_radii[0], available, metal_extent[0])), @max(32, @min(definition.large_radii[1], available, metal_extent[1])), definition.large_radii[2] }
            else
                .{ 5 + @as(u32, @intCast(h % 3)), 5 + @as(u32, @intCast((h >> 8) % 3)), 1 };
            const center_z = if (size_class == .large) world.geography.sea_level - cover - radii[2] else e.terrain_height - cover - radii[2];
            if (center_z < radii[2] + 3 or y < radii[1] + 1 or y + radii[1] + 1 >= self.height) continue;
            var valid_host = true;
            for ([_]i32{ -1, 0, 1 }) |dy| for ([_]i32{ -1, 0, 1 }) |dx| {
                const near = world.baseEnvironmentAt(@as(i64, x) + @as(i64, dx) * radii[0], @intCast(@as(i64, y) + @as(i64, dy) * radii[1]));
                if (near.landmass_id != owner or near.terrain_height <= center_z + radii[2] or (definition.resource == .metal_ore and near.relief != .mountain)) valid_host = false;
            };
            if (!valid_host) continue;
            var d = Deposit{ .id = self.count, .resource = definition.resource, .size_class = size_class, .center = .{ x, y, center_z }, .radii = radii, .priority = definition.priority, .minimum_effective_blocks = 0 };
            if (size_class == .large and !world.geography.protectedBox(x, y, radii[0], radii[1], owner)) continue;
            if (!self.disjoint(d)) continue;
            d.effective_blocks = effectiveCount(world, d, size_class == .large) orelse continue;
            d.minimum_effective_blocks = @intCast(@min(std.math.maxInt(u32), d.effective_blocks));
            return d;
        }
        return null;
    }

    fn effectiveCount(world: anytype, d: Deposit, proven_host: bool) ?u64 {
        var count: u64 = 0;
        var dy: i64 = -@as(i64, d.radii[1]);
        while (dy <= d.radii[1]) : (dy += 1) {
            var dx: i64 = -@as(i64, d.radii[0]);
            while (dx <= d.radii[0]) : (dx += 1) {
                const planar: u64 = @as(u64, @intCast(dx * dx)) * 65536 / (@as(u64, d.radii[0]) * d.radii[0]) + @as(u64, @intCast(dy * dy)) * 65536 / (@as(u64, d.radii[1]) * d.radii[1]);
                if (planar > 65536) continue;
                const threshold = ((65536 - planar + 1) * d.radii[2] * d.radii[2] - 1) / 65536;
                const dz = integerSqrt(@intCast(threshold));
                var low = d.center[2] - dz;
                var high = d.center[2] + dz;
                if (!proven_host) {
                    const x = hash.wrappedX(@as(i64, d.center[0]) + dx, world.layout.size_in_blocks[0]);
                    const y: u32 = @intCast(@as(i64, d.center[1]) + dy);
                    const e = world.baseEnvironmentAt(x, y);
                    const floor = hash.deeprockThickness(world.seed, x, y, world.layout.size_in_blocks[0]);
                    // The whole retained body has its connected centre plane.
                    if (e.water_present or e.terrain_height <= d.center[2] or floor > d.center[2]) return null;
                    low = @max(low, floor);
                    high = @min(high, e.terrain_height - 1);
                    // Preserve generated desert cover from underground overlays.
                    if (e.surface_cover == .sand) {
                        if (e.terrain_height <= 5) return null;
                        high = @min(high, e.terrain_height - 6);
                    }
                }
                if (high >= low) count += high - low + 1;
            }
        }
        return if (count > 0) count else null;
    }

    fn integerSqrt(value: u32) u32 {
        var result: u32 = 0;
        var bit: u32 = 1 << 14;
        var remaining = value;
        while (bit != 0) : (bit >>= 2) {
            if (remaining >= result + bit) {
                remaining -= result + bit;
                result = (result >> 1) + bit;
            } else result >>= 1;
        }
        return result;
    }

    fn disjoint(self: *const Deposits, deposit: Deposit) bool {
        for (self.items[0..self.count]) |other| {
            if (@abs(hash.distanceX(deposit.center[0], other.center[0], self.width)) <= deposit.radii[0] + other.radii[0] + 2 and
                @abs(@as(i64, deposit.center[1]) - other.center[1]) <= deposit.radii[1] + other.radii[1] + 2 and
                @abs(@as(i64, deposit.center[2]) - other.center[2]) <= deposit.radii[2] + other.radii[2] + 2) return false;
        }
        return true;
    }

    pub fn candidates(self: *const Deposits, x: i64, y: u32) []const u8 {
        const bin = @as(usize, y) * 8 / self.height * 8 + @as(usize, hash.wrappedX(x, self.width)) * 8 / self.width;
        return self.bins[bin][0..self.bin_counts[bin]];
    }

    pub fn at(self: *const Deposits, candidates_list: []const u8, x: i64, y: u32, z: u32) ?BlockType {
        var winner: ?Deposit = null;
        for (candidates_list) |index| {
            const deposit = self.items[index];
            if (!deposit.contains(x, y, z, self.width)) continue;
            if (winner == null or deposit.priority < winner.?.priority or (deposit.priority == winner.?.priority and deposit.id < winner.?.id)) winner = deposit;
        }
        return if (winner) |d| definitions[@intFromEnum(d.resource)].block else null;
    }
};
