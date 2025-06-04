const std = @import("std");
const zmath = @import("zmath");

const model_module = @import("./model.zig");
const Model = model_module.Model;
const WindowBoxModel = model_module.WindowBoxModel;

const ModelUnion = union(enum) {
    regular_model: *const Model,
    window_box_model: *const WindowBoxModel,

    pub fn getBoundingRadius(model_union: *const ModelUnion) f32 {
        switch (model_union.*) {
            .regular_model => |model| {
                return model.model_descriptor.geometry_bounds.radius;
            },
            .window_box_model => |model| {
                return model.model_descriptor.geometry_bounds.radius;
            },
        }
    }
};

pub const GameObjectInitParams = struct {
    position: [3]f32,
    rotation: zmath.Quat = zmath.quatFromRollPitchYaw(0, 0, 0),
    scale: f32 = 1.0,
    model: ModelUnion,
};

pub const GameObject = struct {
    allocator: std.mem.Allocator,
    position: [3]f32,
    rotation: zmath.Quat,
    scale: f32,
    aggregated_matrix: zmath.Mat = zmath.identity(),
    bounding_radius: f32,
    model: ModelUnion,
    _gc: ?*GameObject,

    pub fn init(allocator: std.mem.Allocator, params: GameObjectInitParams) !*GameObject {
        const game_object = try allocator.create(GameObject);
        errdefer allocator.destroy(game_object);

        const bounding_radius = params.model.getBoundingRadius();

        game_object.* = GameObject{
            .allocator = allocator,
            .position = params.position,
            .rotation = params.rotation,
            .scale = params.scale,
            .bounding_radius = params.scale * @as(f32, @floatCast(bounding_radius)),
            .model = params.model,
            ._gc = game_object,
        };

        return game_object;
    }

    pub fn setScale(game_object: *GameObject, scale: f32) void {
        game_object.scale = scale;
        game_object.bounding_radius = scale * game_object.model.getBoundingRadius();
    }

    pub fn deinit(game_object: *GameObject) void {
        if (game_object._gc) |pointer| {
            game_object.allocator.destroy(pointer);
        }
    }
};
