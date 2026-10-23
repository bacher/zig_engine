const std = @import("std");
const hash = @import("generation_hash.zig");

pub const ClimateId = enum(u8) { frozen, steppe, temperate, desert };
pub const ReliefId = enum(u8) { lowland, mountain };
pub const VegetationId = enum(u8) { barren, meadow, forest, sparse };
pub const GeologyId = enum(u8) { sedimentary, rocky };
pub const SurfaceCover = enum(u8) { soil, sand, rock };
pub const ClimateMap = [32][32]ClimateId;

pub const WorkRules = struct {
    farming_allowed: bool,
    clothing_required: bool,
    additional_water_required: bool,
    increased_food_cost: bool,
};

pub fn rules(climate: ClimateId) WorkRules {
    return .{
        .farming_allowed = climate != .frozen,
        .clothing_required = climate == .frozen,
        .additional_water_required = climate == .desert,
        .increased_food_cost = climate == .frozen,
    };
}

pub const ColumnEnvironment = struct {
    climate: ClimateId,
    terrain_height: u32,
    sea_level: u32,
    water_present: bool,
    relief: ReliefId,
    mountain_strength: u16,
    vegetation: VegetationId,
    geology: GeologyId,
    surface_cover: SurfaceCover,
    /// Zero denotes ocean, 1..5 mainland, 128..159 detached islands.
    landmass_id: u8,
    coast_distance: u32,

    pub fn workRules(self: ColumnEnvironment) WorkRules {
        return rules(self.climate);
    }
};

pub const ClimateField = struct {
    seed: u64,
    width: u32,
    height: u32,
    displacement: u16,

    /// Boundaries ascend from the storage-south edge to storage-north.
    /// Equality belongs to the belt north of a boundary.
    pub fn boundaries(self: ClimateField, x: i64) [6]u32 {
        const canonical = hash.wrappedX(x, self.width);
        const shares = [_]u32{ 10, 20, 45, 55, 80, 90 };
        var out: [6]u32 = undefined;
        for (shares, 0..) |share, i| {
            const noise = hash.periodic(hash.mix(self.seed +% i), canonical, self.width, @intCast(3 + i % 3));
            const nominal: i64 = @intCast(@as(u64, self.height) * share / 100);
            out[i] = @intCast(nominal + @divTrunc(noise * self.displacement, 65536));
        }
        return out;
    }

    pub fn at(self: ClimateField, x: i64, y: u32) ClimateId {
        std.debug.assert(y < self.height);
        const b = self.boundaries(x);
        const sequence = [_]ClimateId{ .frozen, .steppe, .temperate, .desert, .temperate, .steppe, .frozen };
        for (b, 0..) |boundary, i| if (y < boundary) return sequence[i];
        return .frozen;
    }
};

test "climate fields wrap, preserve ordered polar widths, and expose future work rules" {
    const field = ClimateField{ .seed = 12345, .width = 65536, .height = 32768, .displacement = 96 };
    for (0..1024) |i| {
        const x: i64 = @intCast(i * 64);
        const b = field.boundaries(x);
        try std.testing.expect(b[0] >= 128 and field.height - b[5] >= 128);
        for (0..5) |j| try std.testing.expect(b[j] < b[j + 1]);
        try std.testing.expectEqual(field.at(x, b[2]), field.at(x - field.width, b[2]));
        try std.testing.expectEqual(ClimateId.desert, field.at(x, b[2]));
    }
    try std.testing.expect(!rules(.frozen).farming_allowed);
    try std.testing.expect(rules(.frozen).clothing_required);
    try std.testing.expect(rules(.frozen).increased_food_cost);
    try std.testing.expect(rules(.desert).additional_water_required);
}
