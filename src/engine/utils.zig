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
    position: zmath.Vec,
    rotation: zmath.Quat,
    scale: zmath.Vec,
    scale_scalar: f32,
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
        // TODO: should position have 0.0 or 1.0 as the last element by default?
        .position = position,
        .rotation = rotation,
        .scale = scale_vec,
        .scale_scalar = scale_vec[0],
    };
}

pub fn pos1(pos: zmath.Vec) zmath.Vec {
    var tmp = pos;
    tmp[3] = 1;
    return tmp;
}

pub fn pos0(pos: zmath.Vec) zmath.Vec {
    var tmp = pos;
    tmp[3] = 0;
    return tmp;
}

pub fn applyMat(vec: zmath.Vec, mat: zmath.Mat) zmath.Vec {
    // adding 1 to 4th position of position vector, and forcing it to 0 after
    // the transformation.
    return pos0(zmath.mul(pos1(vec), mat));
}

pub inline fn lengthSq3(vec: zmath.Vec) f32 {
    const dot = vec * vec;
    return dot[0] + dot[1] + dot[2];
}

pub inline fn length3(vec: zmath.Vec) f32 {
    const dot = vec * vec;
    return @sqrt(dot[0] + dot[1] + dot[2]);
}

pub fn updateAggregatedMatrix_abstract(T: anytype, game_object: *T) void {
    game_object.aggregated_matrix = zmath.mul(
        zmath.matFromQuat(game_object.rotation),
        zmath.mul(
            zmath.scaling(
                game_object.scale,
                game_object.scale,
                game_object.scale,
            ),
            zmath.translation(
                game_object.position[0],
                game_object.position[1],
                game_object.position[2],
            ),
        ),
    );
}

pub fn debugPrintMatrix(mat: *const zmath.Mat) void {
    for (0..4) |i| {
        std.debug.print("  {d:10.3} {d:10.3} {d:10.3} {d:10.3}\n", .{
            mat[i][0],
            mat[i][1],
            mat[i][2],
            mat[i][3],
        });
    }
}

pub fn assertMatricesEqual(mat1: *const zmath.Mat, mat2: *const zmath.Mat) void {
    for (0..4) |i| {
        const eq = zmath.isNearEqual(mat1[i], mat2[i], zmath.splat(zmath.Vec, 0.001));
        if (!@reduce(.And, eq == zmath.boolx4(true, true, true, true))) {
            std.debug.print("!!! Matrices are not equal:\n1:\n", .{});
            debugPrintMatrix(mat1);
            std.debug.print("2:\n", .{});
            debugPrintMatrix(mat2);
            std.debug.assert(false);
        }
    }
}
