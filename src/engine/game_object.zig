const std = @import("std");
const zmath = @import("zmath");

const model_module = @import("./model.zig");
const Model = model_module.Model;
const WindowBoxModel = model_module.WindowBoxModel;
const SkyBoxModel = model_module.SkyBoxModel;
const SkyBoxCubemapModel = model_module.SkyBoxCubemapModel;
const PrimitiveModel = model_module.PrimitiveModel;

const ModelUnion = union(enum) {
    regular_model: *const Model,
    window_box_model: *const WindowBoxModel,
    primitive_colorized: *const PrimitiveModel,
    skybox_model: *const SkyBoxModel,
    skybox_cubemap_model: *const SkyBoxCubemapModel,

    pub fn getBoundingRadius(model_union: *const ModelUnion) f32 {
        switch (model_union.*) {
            .regular_model => |model| {
                return model.model_descriptor.geometry_bounds.radius;
            },
            .window_box_model => |model| {
                return model.model_descriptor.geometry_bounds.radius;
            },
            .skybox_model => |model| {
                return model.model_descriptor.geometry_bounds.radius;
            },
            .skybox_cubemap_model => |model| {
                return model.model_descriptor.geometry_bounds.radius;
            },
            .primitive_colorized => |model| {
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
    model: ModelUnion,
    model_bounding_radius: f32,
    debug: struct {
        color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    } = .{},
    _gc: ?*GameObject,

    pub fn init(allocator: std.mem.Allocator, params: GameObjectInitParams) !*GameObject {
        const game_object = try allocator.create(GameObject);
        errdefer allocator.destroy(game_object);

        game_object.* = GameObject{
            .allocator = allocator,
            .position = params.position,
            .rotation = params.rotation,
            .scale = params.scale,
            .aggregated_matrix = undefined,
            .model = params.model,
            .model_bounding_radius = params.model.getBoundingRadius(),
            ._gc = game_object,
        };

        game_object.updateAggregatedMatrix();

        return game_object;
    }

    pub fn setScale(game_object: *GameObject, scale: f32) void {
        game_object.scale = scale;
        game_object.updateAggregatedMatrix();
    }

    pub fn setRotation(game_object: *GameObject, rotation: zmath.Quat) void {
        game_object.rotation = rotation;
        game_object.updateAggregatedMatrix();
    }

    pub fn deinit(game_object: *GameObject) void {
        if (game_object._gc) |pointer| {
            game_object.allocator.destroy(pointer);
        }
    }

    fn updateAggregatedMatrix(game_object: *GameObject) void {
        game_object.aggregated_matrix = zmath.mul(
            zmath.matFromQuat(game_object.rotation),
            zmath.mul(
                zmath.scaling(game_object.scale, game_object.scale, game_object.scale),
                zmath.translation(game_object.position[0], game_object.position[1], game_object.position[2]),
            ),
        );
    }
};
