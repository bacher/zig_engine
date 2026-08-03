const BlockType = @import("engine").voxel_chunk.BlockType;
const Side = @import("engine").voxel_chunk.Side;

const CHUNK_SIZE = 32;

pub const ChunkFlags = packed struct {
    solid_top: bool = false,
    solid_bottom: bool = false,
    solid_front: bool = false,
    solid_back: bool = false,
    solid_left: bool = false,
    solid_right: bool = false,

    pub fn getSideSolidness(self: *const ChunkFlags, side: Side) bool {
        switch (side) {
            .top => return self.solid_top,
            .bottom => return self.solid_bottom,
            .front => return self.solid_front,
            .back => return self.solid_back,
            .left => return self.solid_left,
            .right => return self.solid_right,
        }
    }
};

pub const WorldChunkData = struct {
    blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]BlockType, // [z][y][x]BlockType

    pub fn initUninitialized() WorldChunkData {
        return .{
            .blocks = undefined,
        };
    }

    pub fn initEmpty() WorldChunkData {
        var chunk = WorldChunkData{
            .blocks = undefined,
        };

        @memset(&chunk.blocks, .{.{BlockType.none} ** 32} ** 32);

        return chunk;
    }

    pub fn initFlat() WorldChunkData {
        var chunk = WorldChunkData.initEmpty();

        for (0..(CHUNK_SIZE / 2)) |z| {
            for (0..CHUNK_SIZE) |y| {
                for (0..CHUNK_SIZE) |x| {
                    chunk.blocks[z][y][x] = BlockType.stone;
                }
            }
        }

        return chunk;
    }

    pub fn initSolid() WorldChunkData {
        var chunk = WorldChunkData.initEmpty();

        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |y| {
                for (0..CHUNK_SIZE) |x| {
                    chunk.blocks[z][y][x] = BlockType.stone;
                }
            }
        }

        return chunk;
    }

    pub fn getMetaFlags(self: *const WorldChunkData) ChunkFlags {
        var flags: ChunkFlags = .{
            .solid_top = true,
            .solid_bottom = true,
            .solid_front = true,
            .solid_back = true,
            .solid_left = true,
            .solid_right = true,
        };

        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                if (self.blocks[0][y][x] != .none) {
                    flags.solid_bottom = false;
                }
                if (self.blocks[CHUNK_SIZE - 1][y][x] != .none) {
                    flags.solid_top = false;
                }
            }
        }

        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |y| {
                if (self.blocks[z][y][0] != .none) {
                    flags.solid_left = false;
                }
                if (self.blocks[z][y][CHUNK_SIZE - 1] != .none) {
                    flags.solid_right = false;
                }
            }
        }

        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                if (self.blocks[z][0][x] != .none) {
                    flags.solid_front = false;
                }
                if (self.blocks[z][CHUNK_SIZE - 1][x] != .none) {
                    flags.solid_back = false;
                }
            }
        }

        return flags;
    }
};
