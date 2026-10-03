const BlockType = @import("engine").voxel_chunk.BlockType;
const Side = @import("engine").voxel_chunk.Side;

const CHUNK_SIZE = 32;

pub const ChunkFlags = packed struct {
    /// All six neighboring chunks have solid walls facing this chunk. Generation may
    /// set this flag; revealing the chunk clears it permanently, even if walls are rebuilt.
    is_unreachable: bool = false,
    /// means that the chunk is solid from the left side
    solid_left: bool = false,
    /// means that the chunk is solid from the right side
    solid_right: bool = false,
    /// means that the chunk is solid from the front side
    solid_front: bool = false,
    /// means that the chunk is solid from the back side
    solid_back: bool = false,
    /// means that the chunk is solid from the bottom side
    solid_bottom: bool = false,
    /// means that the chunk is solid from the top side
    solid_top: bool = false,

    pub fn getSideSolidness(self: *const ChunkFlags, side: Side) bool {
        switch (side) {
            .left => return self.solid_left,
            .right => return self.solid_right,
            .front => return self.solid_front,
            .back => return self.solid_back,
            .bottom => return self.solid_bottom,
            .top => return self.solid_top,
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

    pub fn initFilled(block_type: BlockType) WorldChunkData {
        return .{
            .blocks = @splat(@splat(@splat(block_type))),
        };
    }

    pub fn initEmpty() WorldChunkData {
        return initFilled(.none);
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
        chunk.blocks[CHUNK_SIZE / 2 - 1][0][0] = BlockType.snow;
        chunk.blocks[CHUNK_SIZE / 2 - 1][0][1] = BlockType.snow;
        chunk.blocks[CHUNK_SIZE / 2 - 1][1][0] = BlockType.snow;

        return chunk;
    }

    pub fn initSolid() WorldChunkData {
        return initFilled(.stone);
    }

    pub fn countSolidBlocks(self: *const WorldChunkData) u16 {
        var count: u16 = 0;
        for (self.blocks) |layer| {
            for (layer) |row| {
                for (row) |block| {
                    if (block != .none) {
                        count += 1;
                    }
                }
            }
        }
        return count;
    }

    pub fn getMetaFlags(self: *const WorldChunkData) ChunkFlags {
        var flags: ChunkFlags = .{
            .solid_left = true,
            .solid_right = true,
            .solid_front = true,
            .solid_back = true,
            .solid_bottom = true,
            .solid_top = true,
        };

        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                if (self.blocks[0][y][x] == .none) {
                    flags.solid_bottom = false;
                }
                if (self.blocks[CHUNK_SIZE - 1][y][x] == .none) {
                    flags.solid_top = false;
                }
            }
        }

        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |y| {
                if (self.blocks[z][y][0] == .none) {
                    flags.solid_left = false;
                }
                if (self.blocks[z][y][CHUNK_SIZE - 1] == .none) {
                    flags.solid_right = false;
                }
            }
        }

        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                if (self.blocks[z][0][x] == .none) {
                    flags.solid_front = false;
                }
                if (self.blocks[z][CHUNK_SIZE - 1][x] == .none) {
                    flags.solid_back = false;
                }
            }
        }

        return flags;
    }
};
