const std = @import("std");
const math = std.math;
const zmath = @import("zmath");
const zgpu = @import("zgpu");

const GeometryBounds = @import("./types.zig").GeometryBounds;
const utils = @import("./utils.zig");
const model_module = @import("./model.zig");
const Model = model_module.Model;
const WindowBoxModel = model_module.WindowBoxModel;
const SkyBoxModel = model_module.SkyBoxModel;
const SkyBoxCubemapModel = model_module.SkyBoxCubemapModel;
const PrimitiveModel = model_module.PrimitiveModel;
const TerrainHeightMapModel = model_module.TerrainHeightMapModel;
const GameObjectGroup = @import("./game_object_group.zig").GameObjectGroup;
const SpaceTree = @import("./space_tree.zig").SpaceTree;
const BindGroup = @import("./bind_group.zig").BindGroup;
const bind_group_layouts = @import("./bind_group_layouts.zig");
const SkeletalAnimation = @import("./skeletal_animation.zig");

pub const xRotate = zmath.rotationX(0.5 * math.pi);

const ModelUnion = union(enum) {
    regular_model: *const Model,
    window_box_model: *const WindowBoxModel,
    primitive_colorized: *const PrimitiveModel,
    skybox_model: *const SkyBoxModel,
    skybox_cubemap_model: *const SkyBoxCubemapModel,
    terrain_height_map_model: *const TerrainHeightMapModel,

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
            .terrain_height_map_model => {
                return &.unit_geometry_bounds;
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
    instance_index: u32,
};

pub const GameObject = struct {
    allocator: std.mem.Allocator,
    position: [3]f32,
    rotation: zmath.Quat,
    scale: f32,
    aggregated_matrix: zmath.Mat = zmath.identity(),
    model: ModelUnion,
    animation: ?SkeletalAnimation = null,
    joints_bind_group: ?BindGroup = null,
    debug: struct {
        color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    } = .{},
    parent: ?*GameObjectGroup,
    space_tree: ?*SpaceTree(GameObject),
    instance_index: u32,
    _gc: ?*GameObject,

    pub const AnimationContext = struct {
        gctx: *zgpu.GraphicsContext,
        bind_group_layout: bind_group_layouts.JointsBindGroupLayout,
        current_time: f32,
    };

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
            .instance_index = params.instance_index,
            ._gc = game_object,
        };

        game_object.updateAggregatedMatrix(.{
            .is_initial = true,
        });

        return game_object;
    }

    pub fn deinit(game_object: *GameObject, gctx: *zgpu.GraphicsContext) void {
        game_object.stopAnimation(gctx);

        switch (game_object.model) {
            .terrain_height_map_model => |model| {
                // model.deinit(game_object.gctx);
                game_object.allocator.destroy(model);
            },
            else => {},
        }

        if (game_object._gc) |pointer| {
            game_object.allocator.destroy(pointer);
        }
    }

    pub fn getModelMatrix(game_object: *const GameObject) zmath.Mat {
        const flip_yz = switch (game_object.model) {
            .regular_model => |model| model.model_descriptor.options.mesh_y_up,
            else => false,
        };
        if (flip_yz) {
            // NOTE: converting from Y-up to Z-up coordinate system,
            // should be done only for models which is made with Y-up logic.
            return zmath.mul(xRotate, game_object.aggregated_matrix);
        }
        return game_object.aggregated_matrix;
    }

    pub fn playAnimation(
        game_object: *GameObject,
        context: AnimationContext,
        animation_name: []const u8,
    ) !void {
        const model = switch (game_object.model) {
            .regular_model => |model| model,
            else => return error.AnimationNotSupportedForObject,
        };
        const animation_data = model.getSkeletalAnimationData() orelse return error.AnimationNotLoaded;

        if (game_object.animation) |*player| {
            try player.playAnimation(animation_name, context.current_time);
            return;
        }

        const animation = try SkeletalAnimation.init(
            game_object.allocator,
            context.gctx,
            animation_data,
            animation_name,
            context.current_time,
        );
        errdefer animation.deinit(context.gctx);

        const joints_bind_group = try context.bind_group_layout.createBindGroup(
            animation.joint_matrix_buffer.handle,
        );
        errdefer joints_bind_group.deinit(context.gctx);

        game_object.animation = animation;
        game_object.joints_bind_group = joints_bind_group;
    }

    pub fn stopAnimation(game_object: *GameObject, gctx: *zgpu.GraphicsContext) void {
        if (game_object.joints_bind_group) |bind_group| {
            bind_group.deinit(gctx);
            game_object.joints_bind_group = null;
        }

        if (game_object.animation) |animation| {
            animation.deinit(gctx);
            game_object.animation = null;
        }
    }

    pub fn updateAnimation(game_object: *GameObject, gctx: *zgpu.GraphicsContext, time: f32) void {
        if (game_object.animation) |*animation| {
            animation.update(gctx, time);
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
