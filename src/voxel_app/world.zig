const std = @import("std");

const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const ChunkFlags = @import("./world_chunk_data.zig").ChunkFlags;
const BlockPosition = @import("./consts.zig").BlockPosition;
const ChunkPosition = @import("./consts.zig").ChunkPosition;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = @import("./consts.zig").WORLD_SIZE;

pub fn normalizeChunkPosition(x: anytype, y: anytype, z: anytype) [3]u32 {
    var normalized_x = x;
    var normalized_y = y;
    var normalized_z = z;

    if (x >= WORLD_SIZE[0]) {
        normalized_x = x - WORLD_SIZE[0];
    } else if (x < 0) {
        normalized_x = x + WORLD_SIZE[0];
    }
    if (y >= WORLD_SIZE[1]) {
        normalized_y = y - WORLD_SIZE[1];
    } else if (y < 0) {
        normalized_y = y + WORLD_SIZE[1];
    }
    if (z >= WORLD_SIZE[2]) {
        normalized_z = z - WORLD_SIZE[2];
    } else if (z < 0) {
        normalized_z = z + WORLD_SIZE[2];
    }

    return .{
        @intCast(normalized_x),
        @intCast(normalized_y),
        @intCast(normalized_z),
    };
}

pub fn encodeChunkPosition(x: anytype, y: anytype, z: anytype) ChunkPosition {
    return @as(ChunkPosition, @intCast(x)) | @as(ChunkPosition, @intCast(y)) << 12 | @as(ChunkPosition, @intCast(z)) << 20;
}

pub fn encodeChunkPositionArray(coords: anytype) ChunkPosition {
    return encodeChunkPosition(coords[0], coords[1], coords[2]);
}

pub fn decodeChunkPosition(position: ChunkPosition) [3]u32 {
    return .{
        @as(u32, @intCast(position & 0xfff)), //      first 12 bit
        @as(u32, @intCast(position >> 12 & 0xff)), // then 8 bit
        @as(u32, @intCast(position >> 20)), //        and rest (3/4 bit)
    };
}

const WorldChunkState = enum(u8) {
    empty,
    semi_solid,
    solid_loaded,
    solid_unloaded,
};

pub const WorldChunk = struct {
    state: WorldChunkState,
    flags: ChunkFlags,
    world_chunk_data: ?*WorldChunkData,
};

pub const ChunksHashMap = std.AutoHashMapUnmanaged(ChunkPosition, WorldChunk);

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: ChunksHashMap,

    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .chunks = .empty,
        };
    }

    pub fn deinit(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.world_chunk_data) |world_chunk_data| {
                self.allocator.destroy(world_chunk_data);
            }
        }

        self.chunks.deinit(self.allocator);
    }

    pub fn initFlatWorld(self: *World) void {
        const center_z = WORLD_SIZE[2] / 2;

        for (0..WORLD_SIZE[2]) |z| {
            for (0..WORLD_SIZE[1]) |y| {
                for (0..WORLD_SIZE[0]) |x| {
                    var map_chunk: WorldChunk = undefined;

                    if (z == center_z - 1) {
                        const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");

                        world_chunk_data.* = WorldChunkData.initFlat();

                        map_chunk = .{
                            .state = .semi_solid,
                            .flags = WorldChunkData.getMetaFlags(world_chunk_data),
                            .world_chunk_data = world_chunk_data,
                        };
                    } else if (z == center_z - 2) {
                        // const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                        // world_chunk_data.* = WorldChunkData.initSolid();

                        map_chunk = .{
                            .state = .solid_unloaded,
                            // .world_chunk_data = world_chunk_data,
                            .flags = .{},
                            .world_chunk_data = null,
                        };
                    } else if (z < center_z - 2) {
                        map_chunk = .{
                            .state = .solid_unloaded,
                            .flags = .{},
                            .world_chunk_data = null,
                        };
                    } else {
                        map_chunk = .{
                            .state = .empty,
                            .flags = .{},
                            .world_chunk_data = null,
                        };
                    }

                    self.chunks.put(self.allocator, encodeChunkPosition(x, y, z), map_chunk) catch @panic("OOM");
                }
            }
        }
    }
};
