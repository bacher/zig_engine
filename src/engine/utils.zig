const zmath = @import("zmath");

pub fn resolvePosition(position: zmath.Vec) zmath.Vec {
    return zmath.Vec{
        position[0] / position[3],
        position[1] / position[3],
        position[2] / position[3],
        1,
    };
}
