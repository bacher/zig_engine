const std = @import("std");
const chunks = @import("chunk_utils.zig");
const Position = @import("world_math.zig").Position;
const ChunkCoords = @import("world_math.zig").ChunkCoords;
const ChunkId = chunks.ChunkId;

/// Dimensions chosen by the application once, when creating a scene/world.
/// Wrapping belongs to the application's compile-time engine_config.
pub const WorldSettings = struct {
    size_in_chunks: [3]u32,
};

/// Validated coordinate/storage layout. Treat it as immutable for the world's lifetime.
/// IDs are meaningful only within the layout that encoded them.
pub const WorldLayout = struct {
    /// A declaration, not a per-world field: every CPU/shader topology choice is static.
    pub const wrap_x = @import("engine_config").wrap_x;

    size_in_chunks: ChunkCoords,
    size_in_blocks: [3]u32,
    origin_chunk: ChunkCoords,
    id_bits: [3]u5,
    id_shifts: [3]u5,
    id_masks: [3]u32,
    inverse_width: if (wrap_x) f64 else void,

    pub const ValidationError = error{ InvalidWorldDimension, WorldDimensionTooLarge, TooManyChunkIdBits };

    pub fn init(settings: WorldSettings) ValidationError!WorldLayout {
        var layout: WorldLayout = undefined;
        var total_bits: u32 = 0;
        inline for (settings.size_in_chunks, 0..) |size, axis| {
            // At least two chunks preserves the centered-world convention.
            if (size < 2 or !std.math.isPowerOfTwo(size)) return error.InvalidWorldDimension;
            if (size > std.math.maxInt(u32) / chunks.CHUNK_SIZE) return error.WorldDimensionTooLarge;
            const bits: u5 = @intCast(@ctz(size));
            if (total_bits + bits > @bitSizeOf(ChunkId)) return error.TooManyChunkIdBits;
            layout.size_in_chunks[axis] = @intCast(size);
            layout.size_in_blocks[axis] = size * chunks.CHUNK_SIZE;
            layout.origin_chunk[axis] = @intCast(size / 2);
            layout.id_bits[axis] = bits;
            layout.id_shifts[axis] = @intCast(total_bits);
            layout.id_masks[axis] = size - 1;
            total_bits += bits;
        }
        layout.inverse_width = if (comptime wrap_x) 1.0 / @as(f64, @floatFromInt(layout.size_in_chunks[0])) else {};
        return layout;
    }

    pub fn encodeChunkId(self: *const WorldLayout, x: anytype, y: anytype, z: anytype) ChunkId {
        var id: ChunkId = 0;
        inline for (.{ x, y, z }, 0..) |coordinate, axis| {
            std.debug.assert(coordinate >= 0 and coordinate < self.size_in_chunks[axis]);
            id |= @as(ChunkId, @intCast(coordinate)) << self.id_shifts[axis];
        }
        return id;
    }

    pub fn encodeChunkCoords(self: *const WorldLayout, coords: ChunkCoords) ChunkId {
        return self.encodeChunkId(coords[0], coords[1], coords[2]);
    }

    pub fn decodeChunkId(self: *const WorldLayout, id: ChunkId) ChunkCoords {
        var coords: ChunkCoords = undefined;
        inline for (0..3) |axis| {
            coords[axis] = @intCast((id >> self.id_shifts[axis]) & self.id_masks[axis]);
        }
        return coords;
    }

    /// Storage bounds apply to all axes; only x may be normalized periodically.
    pub fn normalizeChunkCoords(self: *const WorldLayout, coords: ChunkCoords) ?ChunkCoords {
        var result = coords;
        if (comptime wrap_x) result[0] = @intCast(@as(u32, @bitCast(coords[0])) & self.id_masks[0]);
        if (!@reduce(.And, result >= @as(ChunkCoords, @splat(0))) or
            !@reduce(.And, result < self.size_in_chunks)) return null;
        return result;
    }

    pub fn getChunkCoords(self: *const WorldLayout, position: Position) ChunkCoords {
        var chunk = @floor(position / @as(Position, @splat(chunks.CHUNK_SIZE))) +
            @as(Position, @floatFromInt(self.origin_chunk));
        if (comptime wrap_x) {
            // Power-of-two width and reciprocal are exact. Wrap before narrowing
            // so repeated trips around x don't overflow GPU i32 coordinates.
            const width: f64 = @floatFromInt(self.size_in_chunks[0]);
            chunk[0] -= @floor(chunk[0] * self.inverse_width) * width;
        }
        return @intFromFloat(chunk);
    }

    pub fn getChunkDelta(self: *const WorldLayout, chunk: ChunkCoords, origin: ChunkCoords) @Vector(3, i64) {
        var delta = @as(@Vector(3, i64), chunk) - @as(@Vector(3, i64), origin);
        if (comptime wrap_x) {
            const width: i64 = self.size_in_chunks[0];
            const a = @as(u32, @bitCast(chunk[0])) & self.id_masks[0];
            const b = @as(u32, @bitCast(origin[0])) & self.id_masks[0];
            delta[0] = @as(i64, a) - @as(i64, b);
            if (delta[0] > @divExact(width, 2)) delta[0] -= width;
            if (delta[0] < -@divExact(width, 2)) delta[0] += width;
        }
        return delta;
    }

    /// Generate literal constants and a topology-specific helper once per pipeline.
    /// The unwrapped variant contains no periodic arithmetic or wrapping branch.
    pub fn shaderSource(self: *const WorldLayout, allocator: std.mem.Allocator, body: []const u8) ![:0]u8 {
        const offset = comptime if (wrap_x) @embedFile("shaders/chunk_offset_wrapped.wgsl") else @embedFile("shaders/chunk_offset_unwrapped.wgsl");
        if (comptime !wrap_x) return std.fmt.allocPrintSentinel(allocator, "const CHUNK_SIZE: f32 = {d}.0;\n{s}\n{s}\n{s}", .{ chunks.CHUNK_SIZE, offset, @embedFile("shaders/chunk_relative.wgsl"), body }, 0);
        return std.fmt.allocPrintSentinel(allocator, "const CHUNK_SIZE: f32 = {d}.0;\nconst WORLD_WIDTH: i32 = {d};\nconst WORLD_X_MASK: u32 = {d}u;\n{s}\n{s}\n{s}", .{ chunks.CHUNK_SIZE, self.size_in_chunks[0], self.id_masks[0], offset, @embedFile("shaders/chunk_relative.wgsl"), body }, 0);
    }
};

test "world dimensions validate storage bounds and the chunk ID budget" {
    const testing = std.testing;
    for ([_]u32{ 0, 1, 3, 31 }) |size| {
        try testing.expectError(error.InvalidWorldDimension, WorldLayout.init(.{ .size_in_chunks = .{ size, 2, 2 } }));
    }
    try testing.expectError(error.WorldDimensionTooLarge, WorldLayout.init(.{ .size_in_chunks = .{ 1 << 27, 2, 2 } }));
    try testing.expectError(error.TooManyChunkIdBits, WorldLayout.init(.{ .size_in_chunks = .{ 1 << 16, 1 << 16, 2 } }));
    const full = try WorldLayout.init(.{ .size_in_chunks = .{ 1 << 15, 1 << 15, 4 } });
    const maximum = full.size_in_chunks - @as(ChunkCoords, @splat(1));
    try testing.expectEqual(std.math.maxInt(u32), full.encodeChunkCoords(maximum));
    try testing.expectEqual(maximum, full.decodeChunkId(std.math.maxInt(u32)));
}

test "different dimensions pack independent IDs with the compiled topology" {
    const a = try WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 } });
    const b = try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 } });
    for ([_]WorldLayout{ a, b }) |layout| {
        const maximum = layout.size_in_chunks - @as(ChunkCoords, @splat(1));
        for (0..8) |corner| {
            var coords: ChunkCoords = @splat(0);
            inline for (0..3) |axis| {
                if (corner & (@as(usize, 1) << axis) != 0) coords[axis] = maximum[axis];
            }
            try std.testing.expectEqual(coords, layout.decodeChunkId(layout.encodeChunkCoords(coords)));
        }
        inline for (0..3) |axis| {
            for (0..layout.id_bits[axis]) |bit| {
                var coords: ChunkCoords = @splat(0);
                coords[axis] = @as(i32, 1) << @as(u5, @intCast(bit));
                try std.testing.expectEqual(@as(usize, 1), @popCount(layout.encodeChunkCoords(coords)));
                try std.testing.expectEqual(coords, layout.decodeChunkId(layout.encodeChunkCoords(coords)));
            }
        }
    }
    try std.testing.expect(a.encodeChunkId(0, 1, 1) != b.encodeChunkId(0, 1, 1));
    if (comptime WorldLayout.wrap_x) {
        try std.testing.expectEqual(ChunkCoords{ 511, 0, 0 }, a.normalizeChunkCoords(.{ -1, 0, 0 }).?);
        try std.testing.expectEqual(ChunkCoords{ 127, 0, 0 }, b.normalizeChunkCoords(.{ -1, 0, 0 }).?);
    } else {
        try std.testing.expectEqual(null, a.normalizeChunkCoords(.{ -1, 0, 0 }));
        try std.testing.expectEqual(null, b.normalizeChunkCoords(.{ -1, 0, 0 }));
    }
    try std.testing.expectEqual(@as(i64, if (WorldLayout.wrap_x) -1 else 511), a.getChunkDelta(.{ 511, 0, 0 }, .{ 0, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i64, if (WorldLayout.wrap_x) -1 else 127), b.getChunkDelta(.{ 127, 0, 0 }, .{ 0, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i64, 256), a.getChunkDelta(.{ 256, 0, 0 }, .{ 0, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i64, -256), a.getChunkDelta(.{ 0, 0, 0 }, .{ 256, 0, 0 })[0]);
}

test "wrapping is compile-time configuration and specializes shader source" {
    try std.testing.expect(!@hasField(WorldSettings, "wrap_x"));
    try std.testing.expect(!@hasField(WorldLayout, "wrap_x"));
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 } });
    const source = try layout.shaderSource(std.testing.allocator, "// shader body");
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(WorldLayout.wrap_x, std.mem.indexOf(u8, source, "WORLD_WIDTH: i32 = 128;") != null);
    try std.testing.expectEqual(WorldLayout.wrap_x, std.mem.indexOf(u8, source, "& WORLD_X_MASK") != null);
    try std.testing.expect(std.mem.endsWith(u8, source, "// shader body"));
    if (comptime !WorldLayout.wrap_x) try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(WorldLayout, "inverse_width")));
}

test "runtime dimensions match reference coordinate math at seams and signed limits" {
    const samples = [_]i32{ std.math.minInt(i32), -16777219, -513, -1, 0, 1, 511, 16777219, std.math.maxInt(i32) };
    const positions = [_]f64{ -1.7e308, -1638400000000.125, -1e9 - 0.25, -8192.125, -32.125, -0.125, 0, 0.125, 32.125, 8192.125, 1e9 + 0.125, 1638400000000.125, 1.7e308 };
    for ([_]u32{ 2, 8, 128, 512, 4096, 1 << 26 }) |width| {
        const layout = try WorldLayout.init(.{ .size_in_chunks = .{ width, 2, 2 } });
        const period: i64 = width;
        for (samples) |a| {
            for (samples) |b| {
                var expected = @as(i64, a) - @as(i64, b);
                if (comptime WorldLayout.wrap_x) {
                    expected = @mod(@as(i64, a), period) - @mod(@as(i64, b), period);
                    if (expected > @divExact(period, 2)) expected -= period;
                    if (expected < -@divExact(period, 2)) expected += period;
                }
                try std.testing.expectEqual(expected, layout.getChunkDelta(.{ a, 0, 0 }, .{ b, 0, 0 })[0]);
            }
        }
        for (positions) |x| {
            const spatial = @floor(x / chunks.CHUNK_SIZE) + @as(f64, @floatFromInt(layout.origin_chunk[0]));
            // Unwrapped inputs must fit the signed GPU coordinate range.
            if (!WorldLayout.wrap_x and (spatial < std.math.minInt(i32) or spatial > std.math.maxInt(i32))) continue;
            const expected: i32 = @intFromFloat(if (comptime WorldLayout.wrap_x) @mod(spatial, @as(f64, @floatFromInt(width))) else spatial);
            try std.testing.expectEqual(expected, layout.getChunkCoords(.{ x, 0, 0 })[0]);
        }
    }
}
