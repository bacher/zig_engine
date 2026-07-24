const BlockType = @import("engine").voxel_chunk.BlockType;

const CHUNK_SIZE = 32;

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
};
