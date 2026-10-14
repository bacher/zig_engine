//! Cell-owned custom geometry. Rendering and collision share the same slope plane.
const std = @import("std");
pub const Direction = enum(u32) {
    positive_x,
    negative_x,
    positive_y,
    negative_y,

    pub fn offset(self: Direction) @Vector(3, i64) {
        return switch (self) {
            .positive_x => .{ 1, 0, 0 },
            .negative_x => .{ -1, 0, 0 },
            .positive_y => .{ 0, 1, 0 },
            .negative_y => .{ 0, -1, 0 },
        };
    }
};

pub const Shape = union(enum) {
    adaptive,
    slope: struct { downhill: Direction, high: f64, low: f64 },

    pub fn gradient(self: Shape) @Vector(2, f64) {
        if (self == .adaptive) return @splat(0);
        const drop = self.slope.high - self.slope.low;
        return switch (self.slope.downhill) {
            .positive_x => .{ -drop, 0 },
            .negative_x => .{ drop, 0 },
            .positive_y => .{ 0, -drop },
            .negative_y => .{ 0, drop },
        };
    }

    pub fn height(self: Shape, x: f64, y: f64) f64 {
        if (self == .adaptive) return 1;
        const t = switch (self.slope.downhill) {
            .positive_x => x,
            .negative_x => 1 - x,
            .positive_y => y,
            .negative_y => 1 - y,
        };
        return self.slope.high + (self.slope.low - self.slope.high) * t;
    }

    /// Highest surface underneath the portion of a rectangular footprint in this cell.
    pub fn supportHeight(self: Shape, min: @Vector(2, f64), max: @Vector(2, f64)) f64 {
        const g = self.gradient();
        return self.height(if (g[0] > 0) max[0] else min[0], if (g[1] > 0) max[1] else min[1]);
    }

    /// Ray against the convex cell volume expanded by a moving body's relative bounds.
    /// Returns the entry fraction in [0, 1]; touching while moving away is not a hit.
    pub fn sweep(self: Shape, start: @Vector(3, f64), delta: @Vector(3, f64), body_min: @Vector(3, f64), body_max: @Vector(3, f64)) ?f64 {
        const g = self.gradient();
        const normal: @Vector(3, f64) = .{ -g[0], -g[1], 1 };
        const normals = [_]@Vector(3, f64){ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, normal };
        const top = if (self == .adaptive) 1 else self.slope.high;
        const limits = [_]f64{ 0, 1, 0, 1, 0, top, self.height(0, 0) };
        var enter: f64 = 0;
        var leave: f64 = 1;
        for (normals, limits) |n, limit| {
            var support: f64 = 0;
            inline for (0..3) |axis| support += n[axis] * (if (n[axis] >= 0) body_min[axis] else body_max[axis]);
            const gap = limit - support - @reduce(.Add, n * start);
            const speed = @reduce(.Add, n * delta);
            if (@abs(speed) < 1e-14) {
                if (gap <= 1e-9) return null;
            } else if (speed < 0) {
                enter = @max(enter, gap / speed);
            } else {
                leave = @min(leave, gap / speed);
            }
            if (enter >= leave - 1e-12) return null;
        }
        return if (enter <= 1 and leave > 0) @max(0, enter) else null;
    }
};

pub const Draw = struct { coords: [3]u8, shape: Shape };

/// 48-byte storage record; each record is submitted as an individual draw.
pub const GPU_CustomBlock = extern struct {
    chunk_origin: [3]i32,
    direction: u32,
    local_origin: [3]f32,
    adaptive: u32,
    high: f32,
    low: f32,
    padding: [2]u32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(GPU_CustomBlock) == 48);
}

test "slope plane and expanded sweep agree in all cardinal directions" {
    for (std.enums.values(Direction)) |direction| {
        const shape: Shape = .{ .slope = .{ .downhill = direction, .high = 0.75, .low = 0.5 } };
        try std.testing.expectApproxEqAbs(@as(f64, 0.625), shape.height(0.5, 0.5), 1e-10);
        const hit = shape.sweep(.{ 0.5, 0.5, 2 }, .{ 0, 0, -2 }, .{ -0.3, -0.3, 0 }, .{ 0.3, 0.3, 1.8 }).?;
        try std.testing.expectApproxEqAbs(@as(f64, 0.65), hit, 1e-10);
        try std.testing.expectEqual(null, shape.sweep(.{ 0.5, 0.5, 0.7 }, .{ 0, 0, 1 }, .{ -0.3, -0.3, 0 }, .{ 0.3, 0.3, 1.8 }));
    }
}
