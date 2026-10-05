const zmath = @import("zmath");
const chunks = @import("chunk_utils.zig");

/// GPU instance data: rotation/scale and a chunk-local translation, followed by
/// integer chunk coordinates. Keep in sync with shaders/chunk_relative.wgsl.
pub const ChunkTransform = extern struct {
    chunk_from_model: zmath.Mat,
    chunk: @Vector(4, i32),

    pub fn init(world_from_model: zmath.Mat) ChunkTransform {
        const position = @as([4]f32, world_from_model[3])[0..3].*;
        const local = chunks.getLocalPosition(position);
        var matrix = world_from_model;
        matrix[3] = .{ local[0], local[1], local[2], 1 };
        return .{ .chunk_from_model = matrix, .chunk = chunks.getChunkCoords(position) };
    }

    pub fn relativeTo(self: ChunkTransform, origin: @Vector(4, i32)) zmath.Mat {
        var matrix = self.chunk_from_model;
        const delta: zmath.Vec = @floatFromInt(chunks.getChunkDelta(self.chunk, origin));
        matrix[3] += delta * @as(zmath.Vec, @splat(chunks.CHUNK_SIZE));
        return matrix;
    }
};
