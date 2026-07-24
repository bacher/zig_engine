const std = @import("std");

const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const BlockPosition = @import("./consts.zig").BlockPosition;
const ChunkPosition = @import("./consts.zig").ChunkPosition;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = @import("./consts.zig").WORLD_SIZE;

pub fn encodeChunkPosition(x: anytype, y: anytype, z: anytype) ChunkPosition {
    return @as(ChunkPosition, @intCast(x)) | @as(ChunkPosition, @intCast(y)) << 12 | @as(ChunkPosition, @intCast(z)) << 20;
}

pub fn decodeChunkPosition(position: ChunkPosition) [3]u32 {
    return .{
        @as(u32, @intCast(position & 0xfff)), //     first 12 bit
        @as(u32, @intCast(position >> 12 & 0xff)), // then 8 bit
        @as(u32, @intCast(position >> 20)), //        and rest (3/4 bit)
    };
}

const MapChunkState = enum(u8) {
    empty,
    semi_solid,
    solid_loaded,
    solid_unloaded,
};

const MapChunk = struct {
    state: MapChunkState,
    world_chunk_data: ?*WorldChunkData,
};

const ChunksHashMap = std.AutoHashMapUnmanaged(ChunkPosition, MapChunk);

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
        for (0..WORLD_SIZE[2]) |z| {
            for (0..WORLD_SIZE[1]) |y| {
                for (0..WORLD_SIZE[1]) |x| { // TODO: change to WORLD_SIZE[0]
                    var map_chunk: MapChunk = undefined;

                    if (z == WORLD_SIZE[2] / 2) {
                        const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");

                        world_chunk_data.* = WorldChunkData.initFlat();

                        map_chunk = .{
                            .state = MapChunkState.semi_solid,
                            .world_chunk_data = world_chunk_data,
                        };
                    } else if (z == (WORLD_SIZE[2] / 2) - 1) {
                        // const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                        // world_chunk_data.* = WorldChunkData.initSolid();

                        map_chunk = .{
                            .state = MapChunkState.solid_unloaded,
                            // .world_chunk_data = world_chunk_data,
                            .world_chunk_data = null,
                        };
                    } else if (z < (WORLD_SIZE[2] / 2) - 1) {
                        map_chunk = .{
                            .state = .solid_unloaded,
                            .world_chunk_data = null,
                        };
                    } else {
                        map_chunk = .{
                            .state = .empty,
                            .world_chunk_data = null,
                        };
                    }

                    self.chunks.put(self.allocator, encodeChunkPosition(x, y, z), map_chunk) catch @panic("OOM");
                }
            }
        }
    }
};
