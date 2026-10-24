//! Bounded, north-up overview of immutable generated geography. Player edits are
//! deliberately absent: building this map never reads or requests voxel chunks.
const std = @import("std");
const engine = @import("engine");
const WorldLayout = engine.WorldLayout;
const Position = engine.world_math.Position;
const generation = @import("world_generator.zig");
const environment = @import("world_environment.zig");

pub const max_raster_side: u32 = 1024;

pub const Raster = struct {
    width: u32,
    height: u32,
    /// Tightly packed RGBA8 rows, with north (+world Y) at the top.
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, prepared: *const generation.PreparedWorldGenerator) std.mem.Allocator.Error!Raster {
        const dimensions = rasterDimensions(prepared.layout);
        const pixels = try allocator.alloc(u8, @as(usize, dimensions.width) * dimensions.height * 4);
        const size = prepared.layout.size_in_blocks;
        for (0..dimensions.height) |py| for (0..dimensions.width) |px| {
            // Sample a single immutable column per pixel, at its cell centre.
            // u64 products also cover the largest validated world dimensions.
            const x: i64 = @intCast((@as(u64, px) * 2 + 1) * size[0] / (@as(u64, dimensions.width) * 2));
            const y = size[1] - 1 - @as(u32, @intCast((@as(u64, py) * 2 + 1) * size[1] / (@as(u64, dimensions.height) * 2)));
            const color = environmentColor(prepared.columnEnvironmentAt(x, y), size[2]);
            @memcpy(pixels[(py * dimensions.width + px) * 4 ..][0..4], &color);
        };
        return .{ .width = dimensions.width, .height = dimensions.height, .pixels = pixels };
    }

    pub fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

const Dimensions = struct { width: u32, height: u32 };

fn rasterDimensions(layout: *const WorldLayout) Dimensions {
    const size = layout.size_in_blocks;
    const longest = @max(size[0], size[1]);
    const side = @min(max_raster_side, longest);
    return .{
        .width = @intCast(@max(1, @as(u64, size[0]) * side / longest)),
        .height = @intCast(@max(1, @as(u64, size[1]) * side / longest)),
    };
}

pub const Marker = struct {
    /// Normalized top-left-origin map coordinates, including bounded edges.
    /// The renderer leaves space around the map for glyphs on its edges.
    uv: [2]f32,
    /// Unit direction in screen pixels, independent of map aspect ratio.
    direction: [2]f32,
};

/// Project engine positions (centred on the world) onto the complete map.
/// Both player and spectator yaw zero face +Y; positive yaw turns toward -X.
pub fn projectMarker(layout: *const WorldLayout, position: Position, yaw: f32) Marker {
    const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
    const height: f64 = @floatFromInt(layout.size_in_blocks[1]);
    const x = if (comptime WorldLayout.wrap_x)
        // Reduce first so adding the origin cannot erase it at large positions.
        @mod(@mod(position[0], width) + width / 2, width)
    else
        std.math.clamp(position[0], -width / 2, width / 2) + width / 2;
    const y = std.math.clamp(position[1], -height / 2, height / 2) + height / 2;
    return .{
        .uv = .{ @floatCast(x / width), @floatCast(1 - y / height) },
        .direction = .{ -@sin(yaw), -@cos(yaw) },
    };
}

fn blend(a: [3]u8, b: [3]u8, amount: u16) [3]u8 {
    var result: [3]u8 = undefined;
    for (&result, a, b) |*component, from, to| {
        component.* = @intCast((@as(u32, from) * (65535 - @as(u32, amount)) + @as(u32, to) * amount) / 65535);
    }
    return result;
}

fn environmentColor(e: environment.ColumnEnvironment, world_height: u32) [4]u8 {
    var color: [3]u8 = undefined;
    if (e.water_present) {
        const depth = e.sea_level -| e.terrain_height;
        const shallowness: u16 = @intCast(65535 - @min(65535, @as(u64, depth) * 65535 / @max(1, e.sea_level)));
        color = blend(.{ 28, 66, 102 }, .{ 49, 115, 150 }, shallowness);
        if (e.climate == .frozen) color = blend(color, .{ 133, 179, 194 }, 28000);
    } else {
        color = switch (e.climate) {
            .frozen => .{ 214, 228, 231 },
            .steppe => .{ 173, 177, 105 },
            .temperate => .{ 115, 157, 85 },
            .desert => .{ 216, 184, 113 },
        };
        if (e.vegetation == .forest) color = blend(color, .{ 40, 101, 60 }, 36000);
        if (e.surface_cover == .sand and e.climate != .frozen) color = blend(color, .{ 224, 201, 143 }, 44000);
        if (e.relief == .mountain) {
            const rock: [3]u8 = if (e.climate == .frozen) .{ 228, 234, 235 } else .{ 149, 139, 121 };
            color = blend(color, rock, @max(22000, e.mountain_strength));
        }
        const elevation = e.terrain_height -| e.sea_level;
        const range = @max(1, world_height -| e.sea_level);
        const brightness = @as(u64, 90) + @min(20, @as(u64, elevation) * 20 / range);
        for (&color) |*component| component.* = @intCast(@min(255, @as(u64, component.*) * brightness / 100));
    }
    return .{ color[0], color[1], color[2], 255 };
}

test "world map raster dimensions preserve aspect and cap the longest side" {
    const cases = [_]struct { chunks: [3]u32, expected: Dimensions }{
        .{ .chunks = .{ 2048, 1024, 32 }, .expected = .{ .width = 1024, .height = 512 } },
        .{ .chunks = .{ 64, 256, 4 }, .expected = .{ .width = 256, .height = 1024 } },
        .{ .chunks = .{ 128, 128, 4 }, .expected = .{ .width = 1024, .height = 1024 } },
        .{ .chunks = .{ 2, 4, 2 }, .expected = .{ .width = 64, .height = 128 } },
        .{ .chunks = .{ 1 << 26, 2, 2 }, .expected = .{ .width = 1024, .height = 1 } },
    };
    for (cases) |case| {
        const layout = try WorldLayout.init(.{ .size_in_chunks = case.chunks });
        try std.testing.expectEqualDeep(case.expected, rasterDimensions(&layout));
    }
}

test "world map marker projects centred coordinates north up and bounds Y" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 4, 2 } });
    const cases = [_]struct { position: Position, uv: [2]f32 }{
        .{ .position = .{ 0, 0, 0 }, .uv = .{ 0.5, 0.5 } },
        .{ .position = .{ -64, 32, 1000000 }, .uv = .{ 0.25, 0.25 } },
        .{ .position = .{ 64, -32, -1000000 }, .uv = .{ 0.75, 0.75 } },
        .{ .position = .{ 0, 64, 0 }, .uv = .{ 0.5, 0 } },
        .{ .position = .{ 0, -64, 0 }, .uv = .{ 0.5, 1 } },
        .{ .position = .{ 0, 1.7e308, 0 }, .uv = .{ 0.5, 0 } },
        .{ .position = .{ 0, -1.7e308, 0 }, .uv = .{ 0.5, 1 } },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.uv, projectMarker(&layout, case.position, 0).uv);
}

test "world map marker respects compiled X wrapping at the seam and repeated laps" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 4, 2 } });
    const at_west = projectMarker(&layout, .{ -128, 0, 0 }, 0);
    const at_east = projectMarker(&layout, .{ 128, 0, 0 }, 0);
    try std.testing.expectEqual(@as(f32, 0), at_west.uv[0]);
    try std.testing.expectEqual(@as(f32, if (WorldLayout.wrap_x) 0 else 1), at_east.uv[0]);
    if (comptime WorldLayout.wrap_x) {
        const expected = projectMarker(&layout, .{ -127.75, 0, 0 }, 0);
        for ([_]f64{ -256000000127.75, -383.75, -127.75, 128.25, 256000000128.25 }) |x| {
            // Both large examples retain the same quarter-block seam offset.
            const actual = projectMarker(&layout, .{ x, 0, 0 }, 0);
            try std.testing.expectEqualDeep(expected.uv, actual.uv);
        }
        try std.testing.expect(projectMarker(&layout, .{ 127.75, 0, 0 }, 0).uv[0] > 0.99);
    } else {
        try std.testing.expectEqual(@as(f32, 0), projectMarker(&layout, .{ -1e12, 0, 0 }, 0).uv[0]);
        try std.testing.expectEqual(@as(f32, 1), projectMarker(&layout, .{ 1e12, 0, 0 }, 0).uv[0]);
    }
    for ([_]f64{ -1.7e308, -1e12, 1e12, 1.7e308 }) |x| {
        const uv = projectMarker(&layout, .{ x, 0, 0 }, 0).uv;
        try std.testing.expect(std.math.isFinite(uv[0]) and uv[0] >= 0 and uv[0] <= 1);
    }
}

test "world map marker heading follows player and spectator yaw in screen pixels" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 4, 2 } });
    const cases = [_]struct { yaw: f32, direction: [2]f32 }{
        .{ .yaw = 0, .direction = .{ 0, -1 } },
        .{ .yaw = std.math.pi / 2.0, .direction = .{ -1, 0 } },
        .{ .yaw = std.math.pi, .direction = .{ 0, 1 } },
        .{ .yaw = -std.math.pi / 2.0, .direction = .{ 1, 0 } },
        .{ .yaw = std.math.pi / 4.0, .direction = .{ -@sqrt(@as(f32, 0.5)), -@sqrt(@as(f32, 0.5)) } },
    };
    for (cases) |case| {
        const actual = projectMarker(&layout, .{ 0, 0, 0 }, case.yaw).direction;
        for (actual, case.direction) |component, expected| try std.testing.expectApproxEqAbs(expected, component, 0.000001);
    }
}

test "world map raster is deterministic for flat and legacy terrain profiles" {
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 4, 4 } });
    for ([_]generation.WorldGenerator{ .flat, .{ .flat_seeded = 12345 }, .{ .terrain = .{ .seed = 12345 } } }) |generator| {
        var prepared = try generator.prepare(allocator, &layout);
        defer prepared.deinit(allocator);
        var first = try Raster.init(allocator, &prepared);
        defer first.deinit(allocator);
        var second = try Raster.init(allocator, &prepared);
        defer second.deinit(allocator);
        try std.testing.expectEqualSlices(u8, first.pixels, second.pixels);
        try std.testing.expectEqual(@as(usize, 64 * 128 * 4), first.pixels.len);
        for (0..first.height) |py| for (0..first.width) |px| {
            const expected = environmentColor(prepared.columnEnvironmentAt(@intCast(px), @intCast(first.height - 1 - py)), layout.size_in_blocks[2]);
            try std.testing.expectEqualSlices(u8, &expected, first.pixels[(py * first.width + px) * 4 ..][0..4]);
        };
    }
}

test "world map palette distinguishes water climate forests and mountains" {
    var column: environment.ColumnEnvironment = .{
        .climate = .temperate,
        .terrain_height = 64,
        .sea_level = 48,
        .water_present = false,
        .relief = .lowland,
        .mountain_strength = 0,
        .vegetation = .meadow,
        .geology = .rocky,
        .surface_cover = .soil,
        .landmass_id = 1,
        .coast_distance = 32,
    };
    const meadow = environmentColor(column, 128);
    try std.testing.expect(meadow[1] > meadow[0] and meadow[1] > meadow[2]);
    column.vegetation = .forest;
    const forest = environmentColor(column, 128);
    try std.testing.expect(forest[1] < meadow[1]);
    column.vegetation = .meadow;
    column.relief = .mountain;
    column.mountain_strength = 65535;
    const mountain = environmentColor(column, 128);
    try std.testing.expect(!std.mem.eql(u8, &meadow, &mountain));
    column.relief = .lowland;
    var climate_colors: [4][4]u8 = undefined;
    for (std.enums.values(environment.ClimateId), 0..) |climate, i| {
        column.climate = climate;
        climate_colors[i] = environmentColor(column, 128);
        for (climate_colors[0..i]) |prior| try std.testing.expect(!std.mem.eql(u8, &prior, &climate_colors[i]));
    }
    column.climate = .temperate;
    column.water_present = true;
    column.terrain_height = 20;
    const water = environmentColor(column, 128);
    try std.testing.expect(water[2] > water[1] and water[1] > water[0]);
    try std.testing.expectEqual(@as(u8, 255), water[3]);
    try std.testing.expect(!std.mem.eql(u8, &meadow, &water));
}

test "world map raster allocation failure does not retain memory" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var prepared = try generation.WorldGenerator.prepare(.flat, std.testing.allocator, &layout);
    defer prepared.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Raster.init(failing.allocator(), &prepared));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
