const std = @import("std");

/// Generator 2/version 1 inputs. All other geometry constants are part of that
/// algorithm version, rather than inferred from a cache or an advancing RNG.
pub const NaturalSettings = struct {
    beaches: bool = false,
    /// Zero selects a layout-scaled amplitude; nonzero values are literal blocks.
    climate_displacement: u16 = 0,
    island_count: u8 = 12,
    large_deposits_per_resource: u8 = 8,
    small_deposits_per_resource: u8 = 12,
    feature_index_capacity: u16 = 64,

    pub const ValidationError = error{ InvalidLayout, InvalidClimateWidths, InvalidCoastBounds, InfeasibleCapacity };

    pub fn climateDisplacement(self: NaturalSettings, height: u32) u32 {
        if (self.climate_displacement != 0) return self.climate_displacement;
        const belt = height / 10;
        return @min(height / 25, belt -| 128, (belt -| 2) / 2);
    }

    /// Dimensions are chunks. This preflight never starts a candidate attempt.
    pub fn validate(self: NaturalSettings, dimensions: [3]u32) ValidationError!void {
        if (dimensions[0] < 64 or dimensions[1] < 64 or dimensions[2] < 4) return error.InvalidLayout;
        if (@as(u64, dimensions[0]) * dimensions[1] / 16 > 1048576) return error.InfeasibleCapacity;
        const height = @as(u64, dimensions[1]) * 32;
        const displacement: u64 = self.climate_displacement;
        if (displacement != 0 and (height / 10 < 128 + displacement or height / 10 <= 2 * displacement + 1))
            return error.InvalidClimateWidths;
        if (self.island_count == 0 or self.island_count > 32) return error.InvalidCoastBounds;
        const mandatory_deposits = @as(u32, self.large_deposits_per_resource) * 5 + @as(u32, self.small_deposits_per_resource) * 3 + 3;
        if (self.large_deposits_per_resource == 0 or self.large_deposits_per_resource > 16 or
            self.small_deposits_per_resource > 24 or self.feature_index_capacity == 0 or
            @as(u32, self.feature_index_capacity) * 64 < mandatory_deposits or
            self.feature_index_capacity > 256) return error.InfeasibleCapacity;
        // Keep all coordinate products exact in signed 64-bit fixed-point fields.
        for (dimensions) |dimension| if (@as(u64, dimension) * 32 > std.math.maxInt(i32)) return error.InvalidLayout;
    }
};

test "automatic climate displacement scales with height and preserves small polar belts" {
    const settings = NaturalSettings{};
    try std.testing.expectEqual(@as(u32, 1310), settings.climateDisplacement(32768));
    try std.testing.expectEqual(@as(u32, 76), settings.climateDisplacement(2048));
    try std.testing.expect(settings.climateDisplacement(2000000) > std.math.maxInt(u16));
    try settings.validate(.{ 64, 64, 4 });
    try std.testing.expectError(error.InvalidClimateWidths, (NaturalSettings{ .climate_displacement = 96 }).validate(.{ 64, 64, 4 }));
    try std.testing.expectEqual(@as(u32, 112), (NaturalSettings{ .climate_displacement = 112 }).climateDisplacement(32768));
    try std.testing.expectError(error.InvalidClimateWidths, (NaturalSettings{ .climate_displacement = 4096 }).validate(.{ 2048, 1024, 32 }));
}
