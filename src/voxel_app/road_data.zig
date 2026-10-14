//! A formed run snapshots its ownership and orientation in every participating cell.
const engine = @import("engine");
const custom = engine.voxel_chunk.custom_block;
pub const BlockIndex = @import("block_transformations.zig").BlockIndex;
pub const Slope = struct {
    high_endpoint: [3]u32,
    downhill: custom.Direction,
    length: u32,
    section: u32,

    pub fn shape(self: Slope) custom.Shape {
        const n: f64 = @floatFromInt(self.length);
        return .{ .slope = .{ .downhill = self.downhill, .high = 1 - @as(f64, @floatFromInt(self.section)) / n, .low = 1 - @as(f64, @floatFromInt(self.section + 1)) / n } };
    }
};
pub const Road = struct {
    index: BlockIndex,
    slope: ?Slope = null,

    pub fn shape(self: Road) custom.Shape {
        return if (self.slope) |slope| slope.shape() else .adaptive;
    }
};
