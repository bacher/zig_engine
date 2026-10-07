const zmath = @import("zmath");
const chunks = @import("chunk_utils.zig");
const WorldLayout = @import("world_layout.zig").WorldLayout;
const world_math = @import("world_math.zig");

/// GPU instance data: rotation/scale and a chunk-local translation, followed by
/// integer chunk coordinates. Keep in sync with shaders/chunk_relative.wgsl.
pub const ChunkTransform = extern struct {
    chunk_from_model: zmath.Mat,
    chunk: @Vector(4, i32),

    pub fn init(layout: *const WorldLayout, world_from_model: world_math.Mat) ChunkTransform {
        const position: world_math.Position = @shuffle(f64, world_from_model[3], undefined, @Vector(3, i32){ 0, 1, 2 });
        const local = chunks.getLocalPosition(position);
        // Narrow only the rotation/scale columns. The absolute translation must
        // never pass through f32; getLocalPosition rebases it first, in f64.
        var matrix: zmath.Mat = undefined;
        inline for (0..3) |i| matrix[i] = @floatCast(world_from_model[i]);
        matrix[3] = .{ local[0], local[1], local[2], 1 };
        const chunk = layout.getChunkCoords(position);
        return .{ .chunk_from_model = matrix, .chunk = .{ chunk[0], chunk[1], chunk[2], 0 } };
    }

    pub fn getChunkCoords(self: ChunkTransform) world_math.ChunkCoords {
        return @shuffle(i32, self.chunk, undefined, @Vector(3, i32){ 0, 1, 2 });
    }

    pub fn relativeTo(self: ChunkTransform, layout: *const WorldLayout, origin: world_math.ChunkCoords) zmath.Mat {
        var matrix = self.chunk_from_model;
        const delta: @Vector(3, f32) = @floatFromInt(layout.getChunkDelta(self.getChunkCoords(), origin));
        const offset = delta * @as(@Vector(3, f32), @splat(chunks.CHUNK_SIZE));
        matrix[3] += zmath.Vec{ offset[0], offset[1], offset[2], 0 };
        return matrix;
    }
};
