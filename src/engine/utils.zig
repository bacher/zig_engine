const zmath = @import("zmath");

pub fn resolvePosition(position: zmath.Vec) zmath.Vec {
    return zmath.Vec{
        position[0] / position[3],
        position[1] / position[3],
        position[2] / position[3],
        1,
    };
}

pub const DecodedTransformMatrix = struct {
    position: [3]f32,
    rotation: zmath.Quat,
    scale: f32,
};

pub fn parseTransformMatrix(matrix: zmath.Mat) DecodedTransformMatrix {
    const position = zmath.mul(zmath.Vec{ 0, 0, 0, 1 }, matrix);
    const rotation = zmath.quatFromMat(matrix);
    const scaled = zmath.mul(zmath.Vec{ 1, 0, 0, 0 }, matrix);

    const cross_product = scaled * scaled;

    return .{
        .position = .{ position[0], position[1], position[2] },
        .rotation = rotation,
        .scale = @sqrt(cross_product[0] + cross_product[1] + cross_product[2]),
    };
}
