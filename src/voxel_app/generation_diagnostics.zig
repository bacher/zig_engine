//! Bounded offline diagnostics. No map census is part of preparation or queries.
const std = @import("std");
const generator = @import("world_generator.zig");
const hash = @import("generation_hash.zig");

pub const Column = struct {
    terrain_height: u32,
    sea_level: u32,
    /// Intended mainland/island owner remains available even after a bad refinement.
    owner: u8 = 0,
    core: bool = false,
    protected_water: bool = false,
    pub fn isLand(self: Column) bool {
        return self.terrain_height >= self.sea_level;
    }
};
pub const TopologyGrid = struct {
    width: u32,
    height: u32,
    columns: []const Column,
    /// Minimum Chebyshev water gap between distinct intended owners (includes corners).
    water_gap: u8 = 1,
};
pub const TopologyReport = struct { land_columns: usize = 0, components: usize = 0, mainlands: usize = 0, islands: usize = 0 };
pub const TopologyError = error{ InvalidGrid, MissingCore, MissingOwner, MultipleCores, UnknownLand, MergedOwners, DisconnectedOwner, ProtectedWaterLost, WaterGapBreached } || std.mem.Allocator.Error;

/// Exhaustive cardinal graph over actual final H/S columns, cylindrical only in X.
/// Used on reduced/adversarial fixtures and explicit offline diagnostics.
pub fn validateTopology(a: std.mem.Allocator, grid: TopologyGrid) TopologyError!TopologyReport {
    if (grid.width == 0 or grid.height == 0 or grid.water_gap > 8 or @as(u64, grid.width) * grid.height != grid.columns.len) return error.InvalidGrid;
    var report: TopologyReport = .{};
    const visited = try a.alloc(bool, grid.columns.len);
    defer a.free(visited);
    @memset(visited, false);
    const queue = try a.alloc(usize, grid.columns.len);
    defer a.free(queue);
    var owners = [_]bool{false} ** 256;
    for (grid.columns, 0..) |column, start| {
        if (column.protected_water and column.isLand()) return error.ProtectedWaterLost;
        if (column.core and !column.isLand()) return error.MissingCore;
        if (!column.isLand() or visited[start]) continue;
        if (column.owner == 0) return error.UnknownLand;
        if (owners[column.owner]) return error.DisconnectedOwner;
        owners[column.owner] = true;
        queue[0] = start;
        visited[start] = true;
        var count: usize = 1;
        var cursor: usize = 0;
        var cores: usize = 0;
        while (cursor < count) : (cursor += 1) {
            const index = queue[cursor];
            const current = grid.columns[index];
            report.land_columns += 1;
            cores += @intFromBool(current.core);
            if (current.owner != column.owner) return error.MergedOwners;
            const x = index % grid.width;
            const y = index / grid.width;
            const neighbors = [_]?usize{
                y * grid.width + (x + grid.width - 1) % grid.width,
                y * grid.width + (x + 1) % grid.width,
                if (y > 0) index - grid.width else null,
                if (y + 1 < grid.height) index + grid.width else null,
            };
            for (neighbors) |neighbor| {
                const next = neighbor orelse continue;
                if (visited[next] or !grid.columns[next].isLand()) continue;
                visited[next] = true;
                queue[count] = next;
                count += 1;
            }
        }
        if (column.owner < 128) {
            if (cores == 0) return error.MissingCore;
            if (cores != 1) return error.MultipleCores;
            report.mainlands += 1;
        } else {
            if (cores != 0) return error.MultipleCores;
            report.islands += 1;
        }
        report.components += 1;
    }
    for (grid.columns) |column| if (column.owner != 0 and !owners[column.owner]) return error.MissingOwner;
    // Connectivity alone misses diagonal approaches and lost clearance corridors.
    for (grid.columns, 0..) |column, index| {
        if (!column.isLand()) continue;
        const x: i64 = @intCast(index % grid.width);
        const y: i64 = @intCast(index / grid.width);
        const gap: i64 = grid.water_gap;
        var dy = -gap;
        while (dy <= gap) : (dy += 1) {
            if (y + dy < 0 or y + dy >= grid.height) continue;
            var dx = -gap;
            while (dx <= gap) : (dx += 1) {
                const nx: usize = @intCast(@mod(x + dx, @as(i64, grid.width)));
                const ny: usize = @intCast(y + dy);
                const neighbor = grid.columns[ny * grid.width + nx];
                if (neighbor.isLand() and neighbor.owner != column.owner) return error.WaterGapBreached;
            }
        }
    }
    return report;
}

pub const SampleReport = struct {
    samples: u64 = 0,
    land: u64 = 0,
    mainland: u64 = 0,
    island: u64 = 0,
    climate_belts: [7]u64 = @splat(0),
    land_climate_belts: [7]u64 = @splat(0),
    relief: [2]u64 = @splat(0),
    land_relief: [2]u64 = @splat(0),
    land_geology: [2]u64 = @splat(0),
    /// Sum of mutable dry-land host depths over sampled columns. Multiplying by
    /// world horizontal area / samples estimates eligible host voxel volume.
    host_depth_by_relief_geology: [2][2]u64 = @splat(@splat(0)),
    vegetation: [4]u64 = @splat(0),
    fingerprint: u64 = 0,

    pub fn landPercent(self: SampleReport) f64 {
        return if (self.samples == 0) 0 else @as(f64, @floatFromInt(self.land)) * 100 / @as(f64, @floatFromInt(self.samples));
    }
};

/// A reproducible jittered grid with O(1) retained memory. Offset passes are
/// estimators; their disagreement is reported without claiming a confidence bound.
pub fn sampleEnvironment(prepared: *const generator.PreparedWorldGenerator, width: u32, height: u32, pass: u64) SampleReport {
    std.debug.assert(width > 0 and height > 0);
    var result: SampleReport = .{};
    const size = prepared.layout.size_in_blocks;
    for (0..height) |py| for (0..width) |px| {
        const h = hash.at(hash.mix(pass), @intCast(px), @intCast(py));
        const x0 = @as(u64, @intCast(px)) * size[0] / width;
        const x1 = @as(u64, @intCast(px + 1)) * size[0] / width;
        const y0 = @as(u64, @intCast(py)) * size[1] / height;
        const y1 = @as(u64, @intCast(py + 1)) * size[1] / height;
        const x: i64 = @intCast(x0 + h % @max(1, x1 - x0));
        const y: u32 = @intCast(y0 + (h >> 32) % @max(1, y1 - y0));
        const e = prepared.columnEnvironmentAt(x, y);
        const belt: usize = switch (e.climate) {
            .frozen => if (y < size[1] / 2) 0 else 6,
            .steppe => if (y < size[1] / 2) 1 else 5,
            .temperate => if (y < size[1] / 2) 2 else 4,
            .desert => 3,
        };
        result.samples += 1;
        result.climate_belts[belt] += 1;
        if (e.terrain_height >= e.sea_level) {
            result.land += 1;
            result.land_climate_belts[belt] += 1;
            result.land_relief[@intFromEnum(e.relief)] += 1;
            result.land_geology[@intFromEnum(e.geology)] += 1;
            const top = e.terrain_height - @min(e.terrain_height, if (e.surface_cover == .sand) @as(u32, 5) else 0);
            const floor = prepared.deeprockThickness(x, y);
            result.host_depth_by_relief_geology[@intFromEnum(e.relief)][@intFromEnum(e.geology)] += top - @min(top, floor);
            if (e.landmass_id >= 128) result.island += 1 else result.mainland += 1;
        }
        result.relief[@intFromEnum(e.relief)] += 1;
        result.vegetation[@intFromEnum(e.vegetation)] += 1;
        result.fingerprint = hash.mix(result.fingerprint ^ @as(u64, e.terrain_height) ^ (@as(u64, @intFromEnum(e.climate)) << 32) ^ (@as(u64, e.landmass_id) << 40) ^ (@as(u64, @intFromEnum(e.vegetation)) << 48));
    };
    return result;
}
