const Model = @import("./model.zig").Model;

pub const GameObject = struct {
    position: [3]f32,
    model: *const Model,
};
