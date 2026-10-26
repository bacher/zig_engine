const std = @import("std");
const BlockType = @import("engine").voxel_chunk.BlockType;
const environment = @import("world_environment.zig");
const hash = @import("generation_hash.zig");
const vegetation = @import("generation_vegetation.zig");

const Fixture = struct {
    layout: struct { size_in_blocks: [3]u32 = .{ 512, 512, 128 } } = .{},
    seed: u64 = 12345,
    report: struct { selected_attempt: ?u8 = 0 } = .{},
    first_start: [3]u32 = .{ 256, 256, 40 },
    base: environment.ColumnEnvironment = .{
        .climate = .temperate,
        .terrain_height = 40,
        .sea_level = 20,
        .water_present = false,
        .relief = .lowland,
        .mountain_strength = 0,
        .vegetation = .forest,
        .geology = .sedimentary,
        .surface_cover = .soil,
        .landmass_id = 1,
        .coast_distance = 200,
    },
    patches: [32]Patch = undefined,
    patch_count: usize = 0,
    sample_count: ?*usize = null,

    const Patch = struct { x: u32, y: u32, value: environment.ColumnEnvironment };

    pub fn baseEnvironmentAt(self: *const Fixture, x: i64, y: u32) environment.ColumnEnvironment {
        std.debug.assert(y < self.layout.size_in_blocks[1]);
        if (self.sample_count) |count| count.* += 1;
        const canonical = hash.wrappedX(x, self.layout.size_in_blocks[0]);
        for (self.patches[0..self.patch_count]) |patch| {
            if (patch.x == canonical and patch.y == y) return patch.value;
        }
        return self.base;
    }

    fn set(self: *Fixture, x: i64, y: u32, value: environment.ColumnEnvironment) void {
        const canonical = hash.wrappedX(x, self.layout.size_in_blocks[0]);
        for (self.patches[0..self.patch_count]) |*patch| {
            if (patch.x == canonical and patch.y == y) {
                patch.value = value;
                return;
            }
        }
        self.patches[self.patch_count] = .{ .x = canonical, .y = y, .value = value };
        self.patch_count += 1;
    }

    fn isolate(self: *Fixture, tree: vegetation.Tree) void {
        var root = self.base;
        self.base.vegetation = .barren;
        root.terrain_height = tree.root[2];
        self.set(tree.root[0], tree.root[1], root);
    }
};

fn findTree(world: *const Fixture, height: u8) vegetation.Tree {
    for (0..16) |cy| for (0..16) |cx| {
        const tree = vegetation.eligible(world, @intCast(cx), @intCast(cy)) orelse continue;
        if (tree.trunk_height == height) return tree;
    };
    unreachable;
}

test "tree clearance retains downhill crowns far above local ground with bounded probes" {
    for ([_]u8{ 4, 5 }) |height| {
        var world = Fixture{};
        var tree = findTree(&world, height);
        tree.root[2] = 60;
        world.isolate(tree);
        var samples: usize = 0;
        world.sample_count = &samples;
        const actual = vegetation.eligible(&world, tree.cell[0], tree.cell[1]).?;
        try std.testing.expectEqualDeep(tree, actual);
        try std.testing.expectEqual(@as(usize, 25), samples);
        try std.testing.expect(vegetation.accepted(&world, actual));

        const x: i64 = @as(i64, tree.root[0]) + 2;
        const y = tree.root[1] + 2;
        const z = tree.root[2] + height - 1;
        try std.testing.expect(z > world.baseEnvironmentAt(x, y).terrain_height + 8);
        try std.testing.expectEqual(@as(?BlockType, .leaves), vegetation.at(&world, x, y, z));
        for (0..8) |dz| for (0..5) |oy| for (0..5) |ox| {
            const tx = @as(i64, tree.root[0]) + @as(i64, @intCast(ox)) - 2;
            const ty: u32 = @intCast(@as(i64, tree.root[1]) + @as(i64, @intCast(oy)) - 2);
            const tz = tree.root[2] + @as(u32, @intCast(dz));
            if (tree.blockAt(tx, ty, tz, world.layout.size_in_blocks[0]) != null) {
                try std.testing.expect(tz >= world.baseEnvironmentAt(tx, ty).terrain_height);
                try std.testing.expect(tz < world.layout.size_in_blocks[2]);
            }
        };
    }
}

test "tree crown clearance accepts touching terrain and rejects every uphill occupied column" {
    for ([_]u8{ 4, 5 }) |height| {
        const tree = findTree(&Fixture{}, height);
        for (0..5) |oy| for (0..5) |ox| {
            if (ox == 2 and oy == 2) continue;
            var world = Fixture{};
            world.isolate(tree);
            const x = @as(i64, tree.root[0]) + @as(i64, @intCast(ox)) - 2;
            const y: u32 = @intCast(@as(i64, tree.root[1]) + @as(i64, @intCast(oy)) - 2);
            var neighbor = world.base;
            neighbor.terrain_height = tree.root[2] + height - 2;
            world.set(x, y, neighbor);
            try std.testing.expectEqualDeep(tree, vegetation.eligible(&world, tree.cell[0], tree.cell[1]).?);
            try std.testing.expectEqual(@as(?BlockType, .leaves), tree.blockAt(x, y, neighbor.terrain_height, 512));
            neighbor.terrain_height += 1;
            world.set(x, y, neighbor);
            try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, tree.cell[0], tree.cell[1]));
        };
    }
}

test "whole tree footprint preserves climate water root mountain and exposed rock exclusions" {
    const tree = findTree(&Fixture{}, 5);
    for (0..5) |oy| for (0..5) |ox| {
        const x = @as(i64, tree.root[0]) + @as(i64, @intCast(ox)) - 2;
        const y: u32 = @intCast(@as(i64, tree.root[1]) + @as(i64, @intCast(oy)) - 2);
        for ([_]environment.ClimateId{ .frozen, .desert }) |climate| {
            var world = Fixture{};
            var other = world.base;
            other.climate = climate;
            world.set(x, y, other);
            try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, tree.cell[0], tree.cell[1]));
        }
        var world = Fixture{};
        var other = world.base;
        other.water_present = true;
        world.set(x, y, other);
        try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, tree.cell[0], tree.cell[1]));
    };
    for ([_]environment.SurfaceCover{ .sand, .rock }) |cover| {
        var world = Fixture{};
        world.base.surface_cover = cover;
        try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, tree.cell[0], tree.cell[1]));
    }
    var world = Fixture{};
    world.base.relief = .mountain;
    try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, tree.cell[0], tree.cell[1]));
    world.base.relief = .lowland;
    world.base.climate = .steppe;
    try std.testing.expect(vegetation.eligible(&world, tree.cell[0], tree.cell[1]) != null);
}

test "whole trees obey finite Y and vertical bounds and wrap their complete clearance footprint" {
    var seam_seen = false;
    var lower_seen = false;
    var upper_seen = false;
    var lower_rejected = false;
    var upper_rejected = false;
    var world = Fixture{};
    for (0..128) |seed| {
        world.seed = seed;
        for ([_]i64{ 0, 63 }) |cy| {
            const h = hash.at(hash.stream(world.seed, .trees, 0), 0, cy);
            if ((h >> 12) % 1_000_000 >= 640_000) continue;
            const y: u32 = @intCast(cy * 8 + @as(i64, @intCast((h >> 3) & 7)));
            const tree = vegetation.eligible(&world, 0, cy);
            if (y < 2 or y + 2 >= 512) {
                try std.testing.expectEqual(@as(?vegetation.Tree, null), tree);
                lower_rejected = lower_rejected or y < 2;
                upper_rejected = upper_rejected or y + 2 >= 512;
            } else {
                try std.testing.expect(tree != null);
                lower_seen = lower_seen or y == 2;
                upper_seen = upper_seen or y == 509;
            }
        }
        for (0..64) |cy| {
            const tree = vegetation.eligible(&world, 0, @intCast(cy)) orelse continue;
            if (tree.root[0] >= 2) continue;
            try std.testing.expectEqualDeep(tree, vegetation.eligible(&world, -64, @intCast(cy)).?);
            var seam = world;
            seam.isolate(tree);
            const z = tree.root[2] + tree.trunk_height - 2;
            try std.testing.expectEqual(@as(?BlockType, .leaves), vegetation.at(&seam, -1, tree.root[1], z));
            var blocker = seam.base;
            blocker.terrain_height = z + 1;
            seam.set(511, tree.root[1], blocker);
            try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&seam, tree.cell[0], tree.cell[1]));
            seam_seen = true;
            break;
        }
        if (seam_seen and lower_seen and upper_seen and lower_rejected and upper_rejected) break;
    }
    try std.testing.expect(seam_seen and lower_seen and upper_seen and lower_rejected and upper_rejected);
    try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, 0, -1));
    try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, 0, 64));
    for ([_]u8{ 4, 5 }) |height| {
        world = .{};
        const tree = findTree(&world, height);
        world.layout.size_in_blocks[2] = tree.root[2] + height + 2;
        try std.testing.expect(vegetation.eligible(&world, tree.cell[0], tree.cell[1]) != null);
        world.layout.size_in_blocks[2] -= 1;
        try std.testing.expectEqual(@as(?vegetation.Tree, null), vegetation.eligible(&world, tree.cell[0], tree.cell[1]));
    }
}

fn conflict(a: vegetation.Tree, b: vegetation.Tree) bool {
    return @abs(hash.distanceX(a.root[0], b.root[0], 512)) <= 5 and @abs(@as(i64, a.root[1]) - b.root[1]) <= 5;
}

test "tree priorities compare all eligible forms and retain a whole block horizontal gap" {
    var world = Fixture{};
    var trees: [256]vegetation.Tree = undefined;
    var count: usize = 0;
    for (0..16) |cy| for (0..16) |cx| {
        const tree = vegetation.eligible(&world, @intCast(cx), @intCast(cy)) orelse continue;
        trees[count] = tree;
        count += 1;
    };
    var chain_seen = false;
    chain: for (trees[0..count]) |a| for (trees[0..count]) |b| {
        if (!conflict(a, b) or b.priority <= a.priority) continue;
        for (trees[0..count]) |c| {
            if (!conflict(b, c) or conflict(a, c) or c.priority <= b.priority) continue;
            var isolated = Fixture{};
            isolated.base.vegetation = .barren;
            for ([_]vegetation.Tree{ a, b, c }) |tree| {
                var root = isolated.base;
                root.vegetation = .forest;
                isolated.set(tree.root[0], tree.root[1], root);
            }
            try std.testing.expect(!vegetation.accepted(&isolated, a));
            try std.testing.expect(!vegetation.accepted(&isolated, b));
            try std.testing.expect(vegetation.accepted(&isolated, c));
            chain_seen = true;
            break :chain;
        }
    };
    try std.testing.expect(chain_seen);
    var accepted_count: usize = 0;
    for (trees[0..count], 0..) |a, index| {
        if (!vegetation.accepted(&world, a)) continue;
        accepted_count += 1;
        for (trees[index + 1 .. count]) |b| {
            if (vegetation.accepted(&world, b)) try std.testing.expect(!conflict(a, b));
        }
    }
    try std.testing.expect(accepted_count > 10 and accepted_count < count);
}
