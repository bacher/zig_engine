const std = @import("std");
const zmath = @import("zmath");

const STRICT = true;

pub fn resolvePosition(position: zmath.Vec) zmath.Vec {
    const result_0 = zmath.Vec{
        position[0] / position[3],
        position[1] / position[3],
        position[2] / position[3],
        1,
    };
    // TODO: What is is more performant:
    //   - explicit divistion (non SIMD)
    //   - @shuffle (SIMD)
    const result = position / @shuffle(f32, position, undefined, [4]i32{ 3, 3, 3, 3 });

    const eq = zmath.isNearEqual(result_0, result, @Vector(4, f32){ 0.0001, 0.0001, 0.0001, 0.0001 });

    if (!@reduce(.And, eq == zmath.boolx4(true, true, true, true))) {
        std.debug.print("!!! result_0: {any}\n", .{result_0});
        std.debug.print("!!! result: {any}\n", .{result});
        std.debug.print("!!! difference: {any}\n", .{result - result_0});
        std.debug.assert(false);
    }

    return result;
}

pub const DecodedTransformMatrix = struct {
    // TODO: use zmath.Vec instead of [3]f32
    position: [3]f32,
    rotation: zmath.Quat,
    scale: f32,
};

pub fn parseTransformMatrix(matrix: zmath.Mat) DecodedTransformMatrix {
    const position = zmath.mul(zmath.Vec{ 0, 0, 0, 1 }, matrix);

    // NOTE: alternative way to get scale (manually)
    // const scaled = zmath.mul(zmath.Vec{ 1, 0, 0, 0 }, matrix);
    // const product = scaled * scaled;
    // const scale = @sqrt(product[0] + product[1] + product[2]);

    const scale_vec = zmath.util.getScaleVec(matrix);

    if (STRICT) {
        if (@abs(scale_vec[0] - scale_vec[1]) > 0.0001 or @abs(scale_vec[0] - scale_vec[2]) > 0.0001) {
            std.debug.print("!!! Non uniform scale detected: {any}\n", .{scale_vec});
        }
    }

    // NOTE: quatFromMat works only with matrices without scaling, so we need to undo scaling
    const rotation = zmath.quatFromMat(zmath.mul(
        matrix,
        zmath.scaling(
            1 / scale_vec[0],
            1 / scale_vec[1],
            1 / scale_vec[2],
        ),
    ));

    return .{
        .position = .{ position[0], position[1], position[2] },
        .rotation = rotation,
        .scale = scale_vec[0],
    };
}
