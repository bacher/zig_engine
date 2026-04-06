const std = @import("std");
const zmath = @import("zmath");

const GeometryBounds = @import("./types.zig").GeometryBounds;
const utils = @import("./utils.zig");
const model_module = @import("./model.zig");
const Model = model_module.Model;
const WindowBoxModel = model_module.WindowBoxModel;
const SkyBoxModel = model_module.SkyBoxModel;
const SkyBoxCubemapModel = model_module.SkyBoxCubemapModel;
const PrimitiveModel = model_module.PrimitiveModel;
const GameObjectGroup = @import("./game_object_group.zig").GameObjectGroup;
const SpaceTree = @import("./space_tree.zig").SpaceTree;

const ModelUnion = union(enum) {
    regular_model: *const Model,
    window_box_model: *const WindowBoxModel,
    primitive_colorized: *const PrimitiveModel,
    skybox_model: *const SkyBoxModel,
    skybox_cubemap_model: *const SkyBoxCubemapModel,

    pub fn getBounds(model_union: *const ModelUnion) *const GeometryBounds {
        switch (model_union.*) {
            .regular_model => |model| {
                return &model.model_descriptor.geometry_bounds;
            },
            .window_box_model => |model| {
                return &model.model_descriptor.geometry_bounds;
            },
            .skybox_model => |model| {
                return &model.model_descriptor.geometry_bounds;
            },
            .skybox_cubemap_model => |model| {
                return &model.model_descriptor.geometry_bounds;
            },
            .primitive_colorized => |model| {
                return &model.model_descriptor.geometry_bounds;
            },
        }
    }
};

pub const GameObjectInitParams = struct {
    position: [3]f32,
    rotation: zmath.Quat = zmath.quatFromRollPitchYaw(0, 0, 0),
    scale: f32 = 1.0,
    model: ModelUnion,
    space_tree: ?*SpaceTree(GameObject),
    parent: ?*GameObjectGroup,
};

pub const GameObject = struct {
    allocator: std.mem.Allocator,
    position: [3]f32,
    rotation: zmath.Quat,
    scale: f32,
    aggregated_matrix: zmath.Mat = zmath.identity(),
    model: ModelUnion,
    debug: struct {
        color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    } = .{},
    parent: ?*GameObjectGroup,
    space_tree: ?*SpaceTree(GameObject),
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
            .parent = params.parent,
            .space_tree = params.space_tree,
            ._gc = game_object,
        };

        game_object.updateAggregatedMatrix(.{
            .is_initial = true,
        });

        return game_object;
    }

    pub fn deinit(game_object: *GameObject) void {
        if (game_object._gc) |pointer| {
            game_object.allocator.destroy(pointer);
        }
    }

    pub fn setScale(game_object: *GameObject, scale: f32) void {
        game_object.scale = scale;
        game_object.updateAggregatedMatrix(.{});
    }

    pub fn setRotation(game_object: *GameObject, rotation: zmath.Quat) void {
        game_object.rotation = rotation;
        game_object.updateAggregatedMatrix(.{});
    }

    pub fn setPosition(game_object: *GameObject, position: [3]f32) void {
        game_object.position = position;
        game_object.updateAggregatedMatrix(.{});
    }

    pub fn setParent(game_object: *GameObject, parent: ?*GameObjectGroup) void {
        game_object.parent = parent;
        game_object.updateAggregatedMatrix(.{});
    }

    pub fn onParentUpdated(game_object: *GameObject) void {
        game_object.updateAggregatedMatrix(.{});
    }

    fn updateAggregatedMatrix(game_object: *GameObject, options: struct {
        is_initial: bool = false,
    }) void {
        if (!options.is_initial) {
            if (game_object.space_tree) |space_tree| {
                space_tree.removeObject(game_object) catch {
                    std.debug.print("failed to remove object from space tree\n", .{});
                };
            }
        }

        utils.updateAggregatedMatrix_abstract(GameObject, game_object);

        // if game object has parent, multiply its aggregated matrix by parent's
        // aggregated matrix on each update
        if (game_object.parent) |parent| {
            game_object.aggregated_matrix = zmath.mul(
                game_object.aggregated_matrix,
                parent.aggregated_matrix,
            );
        }

        if (game_object.space_tree) |space_tree| {
            space_tree.addObject(game_object) catch {
                std.debug.print("failed to add object to space tree\n", .{});
            };
        }
    }
};
