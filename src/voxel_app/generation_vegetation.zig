const std = @import("std");
const BlockType = @import("engine").voxel_chunk.BlockType;
const hash = @import("generation_hash.zig");

pub const Tree = struct {
    cell: [2]i64,
    root: [3]u32,
    trunk_height: u8,
    priority: u64,

    pub fn blockAt(self: Tree, x: i64, y: u32, z: u32, width: u32) ?BlockType {
        const dx = @abs(hash.distanceX(x, self.root[0], width));
        const dy = @abs(@as(i64, y) - self.root[1]);
        if (z >= self.root[2] and z < self.root[2] + self.trunk_height and dx == 0 and dy == 0) return .tree_trunk;
        if (z < self.root[2] + self.trunk_height - 2 or z >= self.root[2] + self.trunk_height + 2) return null;
        const radius: u32 = if (z < self.root[2] + self.trunk_height) 2 else 1;
        return if (dx <= radius and dy <= radius) .leaves else null;
    }
};

pub fn eligible(world: anytype, raw_x: i64, cell_y: i64) ?Tree {
    const size = world.layout.size_in_blocks;
    if (cell_y < 0 or cell_y >= size[1] / 8) return null;
    const cell_x = @mod(raw_x, @as(i64, size[0] / 8));
    const seed = hash.stream(world.seed, .trees, world.report.selected_attempt orelse 0);
    const h = hash.at(seed, cell_x, cell_y);
    const x: u32 = @intCast(cell_x * 8 + @as(i64, @intCast(h & 7)));
    const y: u32 = @intCast(cell_y * 8 + @as(i64, @intCast((h >> 3) & 7)));
    if (y < 2 or y + 2 >= size[1]) return null;
    // Clear the spawn and the three explicitly validated dry access routes.
    if (@abs(hash.distanceX(x, world.first_start[0], size[0])) <= 80 and @abs(@as(i64, y) - world.first_start[1]) <= 80) return null;
    const e = world.baseEnvironmentAt(x, y);
    const density: u64 = switch (e.vegetation) {
        .forest => 100,
        .meadow => 5,
        .sparse => 1,
        .barren => return null,
    };
    if ((h >> 12) % 1_000_000 >= density * 6400 or e.water_present or e.surface_cover != .soil or e.relief == .mountain) return null;
    const trunk_height: u8 = @intCast(4 + ((h >> 40) & 1));
    if (e.terrain_height + trunk_height + 2 > size[2]) return null;
    for (0..5) |oy| for (0..5) |ox| {
        const nx = @as(i64, x) + @as(i64, @intCast(ox)) - 2;
        const ny: u32 = @intCast(@as(i64, y) + @as(i64, @intCast(oy)) - 2);
        const trunk_column = ox == 2 and oy == 2;
        const other = if (trunk_column) e else world.baseEnvironmentAt(nx, ny);
        // Terrain occupies every block below terrain_height. Check the first
        // occupied tree block in each column: the trunk root at the center,
        // and the radius-two crown floor everywhere else. Downhill terrain
        // needs no flatness restriction; the whole form remains clear above it.
        const lowest_block = e.terrain_height + if (trunk_column) @as(u32, 0) else trunk_height - 2;
        if (other.climate == .frozen or other.climate == .desert or other.water_present or other.terrain_height > lowest_block) return null;
    };
    return .{ .cell = .{ cell_x, cell_y }, .root = .{ x, y, e.terrain_height }, .trunk_height = trunk_height, .priority = hash.mix(h ^ 0x5052494f52495459) };
}

fn conflicts(a: Tree, b: Tree, width: u32) bool {
    // Radius-two crowns plus a full empty block between horizontal bounds.
    return @abs(hash.distanceX(a.root[0], b.root[0], width)) <= 5 and @abs(@as(i64, a.root[1]) - b.root[1]) <= 5;
}

fn higher(a: Tree, b: Tree) bool {
    return a.priority > b.priority or (a.priority == b.priority and (a.cell[1] < b.cell[1] or (a.cell[1] == b.cell[1] and a.cell[0] < b.cell[0])));
}

pub fn accepted(world: anytype, tree: Tree) bool {
    for (0..3) |oy| for (0..3) |ox| {
        if (ox == 1 and oy == 1) continue;
        const other = eligible(world, tree.cell[0] + @as(i64, @intCast(ox)) - 1, tree.cell[1] + @as(i64, @intCast(oy)) - 1) orelse continue;
        // Compare every eligible candidate, including candidates that lose a
        // different comparison. No recursive greedy/load-order acceptance.
        if (conflicts(tree, other, world.layout.size_in_blocks[0]) and higher(other, tree)) return false;
    };
    return true;
}

pub fn collect(world: anytype, coords: @Vector(2, i32), out: *[64]Tree) usize {
    const width = world.layout.size_in_blocks[0];
    const x = @as(i64, coords[0]) * 32;
    const y = @as(i64, coords[1]) * 32;
    const first_x = @divFloor(x - 2, 8) - 1;
    const last_x = @divFloor(x + 33, 8) + 1;
    const first_y = @divFloor(y - 2, 8) - 1;
    const last_y = @divFloor(y + 33, 8) + 1;
    const columns: usize = @intCast(last_x - first_x + 1);
    const rows: usize = @intCast(last_y - first_y + 1);
    std.debug.assert(columns <= 8 and rows <= 8);
    var candidates: [64]?Tree = @splat(null);
    for (0..rows) |row| for (0..columns) |column| {
        candidates[row * columns + column] = eligible(world, first_x + @as(i64, @intCast(column)), first_y + @as(i64, @intCast(row)));
    };
    var count: usize = 0;
    for (1..rows - 1) |row| for (1..columns - 1) |column| {
        const tree = candidates[row * columns + column] orelse continue;
        var wins = true;
        for (row - 1..row + 2) |ny| for (column - 1..column + 2) |nx| {
            if (nx == column and ny == row) continue;
            const other = candidates[ny * columns + nx] orelse continue;
            if (conflicts(tree, other, width) and higher(other, tree)) wins = false;
        };
        if (wins) {
            out[count] = tree;
            count += 1;
        }
    };
    return count;
}

pub fn at(world: anytype, x: i64, y: u32, z: u32) ?BlockType {
    const canonical = hash.wrappedX(x, world.layout.size_in_blocks[0]);
    const cell_x: i64 = @intCast(canonical / 8);
    const cell_y: i64 = @intCast(y / 8);
    for (0..3) |oy| for (0..3) |ox| {
        const tree = eligible(world, cell_x + @as(i64, @intCast(ox)) - 1, cell_y + @as(i64, @intCast(oy)) - 1) orelse continue;
        const block = tree.blockAt(x, y, z, world.layout.size_in_blocks[0]) orelse continue;
        if (accepted(world, tree)) return block;
    };
    return null;
}

pub fn trunkRootAt(world: anytype, x: i64, y: u32) bool {
    const canonical = hash.wrappedX(x, world.layout.size_in_blocks[0]);
    const seed = hash.stream(world.seed, .trees, world.report.selected_attempt orelse 0);
    const h = hash.at(seed, canonical / 8, y / 8);
    if (canonical % 8 != (h & 7) or y % 8 != ((h >> 3) & 7)) return false;
    const tree = eligible(world, canonical / 8, y / 8) orelse return false;
    return tree.root[0] == canonical and tree.root[1] == y and accepted(world, tree);
}

test {
    _ = @import("generation_vegetation_tests.zig");
}
