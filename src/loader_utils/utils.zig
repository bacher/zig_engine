const std = @import("std");
const math = std.math;
const zmath = @import("zmath");

const debug = @import("debug");

pub fn convertMatFromUpYToZ(mat: zmath.Mat) zmath.Mat {
    const S = struct {
        var identity_mat = zmath.identity();
    };

    S.identity_mat[0][0] = mat[0][0];
    S.identity_mat[0][1] = -mat[0][2];
    S.identity_mat[0][2] = mat[0][1];
    S.identity_mat[0][3] = mat[0][3];

    S.identity_mat[1][0] = -mat[2][0];
    S.identity_mat[1][1] = mat[2][2];
    S.identity_mat[1][2] = -mat[2][1];
    S.identity_mat[1][3] = -mat[2][3];

    S.identity_mat[2][0] = mat[1][0];
    S.identity_mat[2][1] = -mat[1][2];
    S.identity_mat[2][2] = mat[1][1];
    S.identity_mat[2][3] = mat[1][3];

    S.identity_mat[3][0] = mat[3][0];
    S.identity_mat[3][1] = -mat[3][2];
    S.identity_mat[3][2] = mat[3][1];
    S.identity_mat[3][3] = mat[3][3];

    return S.identity_mat;
}

test "matrices" {
    // const model_matrix = zmath.matFromArr(.{
    //     0,  1,  2,  3,
    //     4,  5,  6,  7,
    //     8,  9,  10, 11,
    //     12, 13, 14, 15,
    // });
    const model_matrix = zmath.matFromArr(.{
        0.0,                0.0,                -0.4083702862262726, 0.0,
        0.0,                0.4083702862262726, 0.0,                 0.0,
        0.4083698093891144, 0.0,                0.0,                 0.0,
        3.0450844764709473, 0.7969833612442017, 19.75855827331543,   1.0,
    });

    const in = zmath.matFromNormAxisAngle(.{ 1, 0, 0, 0 }, -0.5 * math.pi);
    const out = zmath.matFromNormAxisAngle(.{ 1, 0, 0, 0 }, 0.5 * math.pi);

    const res1 = zmath.mul(zmath.mul(in, model_matrix), out);
    const res2 = convertMatFromUpYToZ(model_matrix);

    std.debug.assert(debug.areMatricesEqual(res1, res2));
}
