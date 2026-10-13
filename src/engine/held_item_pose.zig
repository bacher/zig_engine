//! Shared resting pose and motion composition for any camera-held tool.
const std = @import("std");
const zmath = @import("zmath");
const utils = @import("utils.zig");
const Offset = @import("held_item_motion.zig").Offset;

pub const Pose = struct {
    /// Projected centre: x right, y up, with visible bounds from -1 to 1.
    screen_position: [2]f32 = .{ 0, -1.05 },
    distance: f32 = 1.5,
    /// Camera-space pitch, yaw, and roll, applied after orienting the item Z-up.
    rotation_degrees: [3]f32 = .{ 12, 40, -0.1 },
    scale: f32 = 0.5148,
    /// Model-space grip point, anchored at screen_position and used as the rotation pivot.
    pivot: [3]f32 = .{ 0.5, 0.5, 0.5 },
    motion: Offset = .{},

    pub fn withMotion(pose: Pose, offset: Offset) Pose {
        var result = pose;
        result.motion = offset;
        return result;
    }

    pub fn viewFromItem(pose: Pose, projection: zmath.Mat) zmath.Mat {
        const radians = std.math.pi / 180.0;
        // Apply the pitch after yaw so turning the item does not lean its up axis.
        const rotation = utils.matMul(zmath.rotationZ(pose.rotation_degrees[2] * radians), utils.matMul(
            zmath.rotationX(pose.rotation_degrees[0] * radians),
            utils.matMul(zmath.rotationY(pose.rotation_degrees[1] * radians), zmath.rotationX(-std.math.pi / 2.0)),
        ));
        // Rotate around the item's pivot; translation is always in view metres.
        return utils.matMul(zmath.translation(
            pose.screen_position[0] * pose.distance / projection[0][0] + pose.motion.translation[0],
            pose.screen_position[1] * pose.distance / projection[1][1] + pose.motion.translation[1],
            -pose.distance + pose.motion.translation[2],
        ), utils.matMul(pose.motion.rotation(), utils.matMul(rotation, utils.matMul(
            zmath.scaling(pose.scale, pose.scale, pose.scale),
            zmath.translation(-pose.pivot[0], -pose.pivot[1], -pose.pivot[2]),
        ))));
    }
};
