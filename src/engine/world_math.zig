const zmath = @import("zmath");

/// CPU positions and accumulated transforms. Matrices use the same column
/// convention as WGSL/zmath; no narrowing conversion is provided here.
pub const Position = @Vector(3, f64);
/// Signed spatial chunk coordinates. Convert explicitly at storage/GPU boundaries.
pub const ChunkCoords = @Vector(3, i32);
pub const Vec = @Vector(4, f64);
pub const Mat = [4]Vec;

pub fn identity() Mat {
    return .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
}

/// Widen asset-local matrices and rotation/scale matrices before composition.
pub fn fromFloat32(matrix: zmath.Mat) Mat {
    var result: Mat = undefined;
    inline for (0..4) |i| result[i] = @floatCast(matrix[i]);
    return result;
}

pub fn translation(x: f64, y: f64, z: f64) Mat {
    var result = identity();
    result[3] = .{ x, y, z, 1 };
    return result;
}

pub fn fromSRT(position: Position, rotation: zmath.Quat, scale: f32) Mat {
    var result = fromFloat32(zmath.matFromQuat(rotation));
    inline for (0..3) |i| result[i] *= @as(Vec, @splat(@as(f64, scale)));
    result[3] = .{ position[0], position[1], position[2], 1 };
    return result;
}

pub fn matApply(matrix: Mat, vector: Vec) Vec {
    return matrix[0] * @as(Vec, @splat(vector[0])) +
        matrix[1] * @as(Vec, @splat(vector[1])) +
        matrix[2] * @as(Vec, @splat(vector[2])) +
        matrix[3] * @as(Vec, @splat(vector[3]));
}

/// parent_from_local * local_from_child, entirely in f64.
pub fn matMul(parent: Mat, child: Mat) Mat {
    var result: Mat = undefined;
    inline for (0..4) |i| result[i] = matApply(parent, child[i]);
    return result;
}
