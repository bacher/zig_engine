const std = @import("std");
const Side = @import("engine").voxel_chunk.Side;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;

/// One bit per occluding block. Opposite faces use identical, unmirrored coordinates:
/// x faces store rows of y bits indexed by z; y faces x by z; z faces x by y.
pub const BoundaryMask = struct {
    rows: [CHUNK_SIZE]u32 = @splat(0),

    pub fn contains(self: *const BoundaryMask, side: Side, local: [3]u5) bool {
        const bit, const row = project(side, local);
        return self.rows[row] & (@as(u32, 1) << bit) != 0;
    }

    pub fn set(self: *BoundaryMask, side: Side, local: [3]u5, solid: bool) void {
        const bit, const row = project(side, local);
        const bit_mask = @as(u32, 1) << bit;
        if (solid) self.rows[row] |= bit_mask else self.rows[row] &= ~bit_mask;
    }

    fn project(side: Side, local: [3]u5) struct { u5, u5 } {
        return switch (side) {
            .left, .right => .{ local[1], local[2] },
            .front, .back => .{ local[0], local[2] },
            .bottom, .top => .{ local[0], local[1] },
        };
    }
};

/// For a chunk's own boundaries, indexed by its outward side. For meshing dependencies,
/// indexed by the receiving chunk's side and containing the neighbor's opposite plane.
pub const BoundaryMasks = [6]BoundaryMask;

pub fn getFlags(masks: *const BoundaryMasks) @import("./world_chunk_data.zig").ChunkFlags {
    var solid: [6]bool = @splat(true);
    for (masks, 0..) |mask, i| {
        for (mask.rows) |row| solid[i] = solid[i] and row == std.math.maxInt(u32);
    }
    return .{
        .solid_left = solid[0],
        .solid_right = solid[1],
        .solid_front = solid[2],
        .solid_back = solid[3],
        .solid_bottom = solid[4],
        .solid_top = solid[5],
    };
}

pub fn extract(data: *const WorldChunkData) BoundaryMasks {
    var masks: BoundaryMasks = @splat(.{});
    for (std.enums.values(Side)) |side| {
        const i = @intFromEnum(side);
        const axis = i / 2;
        for (0..CHUNK_SIZE) |row| {
            for (0..CHUNK_SIZE) |bit| {
                var local: [3]u5 = undefined;
                local[axis] = if (i % 2 == 0) 0 else CHUNK_SIZE - 1;
                local[if (axis == 0) 1 else 0] = @intCast(bit);
                local[if (axis == 2) 1 else 2] = @intCast(row);
                masks[i].set(side, local, data.blocks[local[2]][local[1]][local[0]] != .none);
            }
        }
    }
    return masks;
}

/// Interior edits touch no planes; face, edge and corner edits touch one, two or three.
pub fn update(masks: *BoundaryMasks, local: [3]u5, solid: bool) void {
    for (std.enums.values(Side)) |side| {
        const i = @intFromEnum(side);
        if (local[i / 2] == (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1))
            masks[i].set(side, local, solid);
    }
}

test "boundary masks occupy 128 bytes per plane and preserve every face coordinate" {
    try std.testing.expectEqual(128, @sizeOf(BoundaryMask));
    try std.testing.expectEqual(768, @sizeOf(BoundaryMasks));
    var data = WorldChunkData.initEmpty();
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                if ((x * 3 + y * 5 + z * 7) % 11 < 4) data.blocks[z][y][x] = .stone;
            }
        }
    }
    const masks = extract(&data);
    for (std.enums.values(Side)) |side| {
        const axis = @intFromEnum(side) / 2;
        for (0..CHUNK_SIZE) |a| {
            for (0..CHUNK_SIZE) |b| {
                var local: [3]u5 = undefined;
                local[axis] = if (@intFromEnum(side) % 2 == 0) 0 else CHUNK_SIZE - 1;
                local[(axis + 1) % 3] = @intCast(a);
                local[(axis + 2) % 3] = @intCast(b);
                const expected = data.blocks[local[2]][local[1]][local[0]] != .none;
                try std.testing.expectEqual(expected, masks[@intFromEnum(side)].contains(side, local));
                try std.testing.expectEqual(expected, masks[@intFromEnum(side)].contains(side.getOpposite(), local));
            }
        }
    }
}
