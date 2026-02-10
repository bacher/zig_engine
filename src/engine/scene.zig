const std = @import("std");
const zmath = @import("zmath");

const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;
const GameObjectGroup = @import("./game_object_group.zig").GameObjectGroup;
const WindowBoxModel = @import("./model.zig").WindowBoxModel;
const SkyBoxModel = @import("./model.zig").SkyBoxModel;
const SkyBoxCubemapModel = @import("./model.zig").SkyBoxCubemapModel;
const PrimitiveModel = @import("./model.zig").PrimitiveModel;
const Camera = @import("./camera.zig").Camera;
const SpaceTree = @import("./space_tree.zig").SpaceTree;
const SpectatorCamera = @import("./spectator_camera.zig").SpectatorCamera;
const light_module = @import("./light.zig");
const DirectionalLight = light_module.DirectionalLight;
const DirectionalLightParams = light_module.DirectionalLightParams;

pub const Scene = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject) = .empty,
    root_groups: std.ArrayList(*GameObjectGroup) = .empty,
    // TODO: Maybe store light as a value instead of a pointer?
    lights: std.ArrayList(*DirectionalLight) = .empty,
    space_tree: *SpaceTree(GameObject),
    camera: *Camera,
    spectator_camera: *SpectatorCamera,
    previous_frame_time: f64,

    pub fn init(
        engine: *Engine,
        allocator: std.mem.Allocator,
    ) !*Scene {
        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);

        const space_tree = try SpaceTree(GameObject).init(allocator);
        errdefer space_tree.deinit();

        const camera = try allocator.create(Camera);
        errdefer allocator.destroy(camera);
        camera.* = Camera.init(engine.aspect_ratio);

        const spectator_camera = try allocator.create(SpectatorCamera);
        errdefer allocator.destroy(spectator_camera);
        spectator_camera.* = SpectatorCamera.init(camera, engine.input_controller);

        scene.* = .{
            .engine = engine,
            .allocator = allocator,
            .game_objects = .empty,
            .root_groups = .empty,
            .lights = .empty,
            .space_tree = space_tree,
            .camera = camera,
            .spectator_camera = spectator_camera,
            .previous_frame_time = 0,
        };
        return scene;
    }

    pub fn deinit(scene: *Scene) void {
        for (scene.lights.items) |light| {
            scene.allocator.destroy(light);
        }
        scene.lights.deinit(scene.allocator);

        scene.space_tree.deinit();

        for (scene.root_groups.items) |root_group| {
            root_group.deinit_recursively();
        }
        scene.root_groups.deinit(scene.allocator);

        for (scene.game_objects.items) |game_object| {
            scene.allocator.destroy(game_object);
        }
        scene.game_objects.deinit(scene.allocator);

        scene.spectator_camera.deinit();
        scene.camera.deinit();
        scene.allocator.destroy(scene.camera);
        scene.allocator.destroy(scene.spectator_camera);
        scene.allocator.destroy(scene);
    }

    pub fn addGroup(scene: *Scene) !*GameObjectGroup {
        const new_group = try GameObjectGroup.init(scene.allocator);
        try scene.root_groups.append(scene.allocator, new_group);
        return new_group;
    }

    pub fn addObject(scene: *Scene, params: AddObjectParams) !*GameObject {
        if (scene.engine.models_hash.get(params.model_id)) |model| {
            const game_object = try GameObject.init(scene.allocator, .{
                .model = .{
                    .regular_model = model,
                },
                .position = params.position,
            });
            errdefer game_object.deinit();

            try scene.game_objects.append(scene.allocator, game_object);

            try scene.space_tree.addObject(game_object);

            return game_object;
        } else {
            return error.InvalidModelId;
        }
    }

    // TODO: deduplicate with addObject
    pub fn addWindowBoxObject(scene: *Scene, params: AddWindowBoxParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .window_box_model = params.model,
            },
            .position = params.position,
        });
        errdefer game_object.deinit();

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    pub fn addSkyBoxObject(scene: *Scene, params: AddSkyBoxParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .skybox_model = params.model,
            },
            .position = .{ 0, 0, 0 },
        });
        errdefer game_object.deinit();

        try scene.game_objects.append(game_object);

        return game_object;
    }

    pub fn addSkyBoxCubemapObject(scene: *Scene, params: AddSkyBoxCubemapParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .skybox_cubemap_model = params.model,
            },
            .position = .{ 0, 0, 0 },
        });
        errdefer game_object.deinit();

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    pub fn addPrimitiveObject(scene: *Scene, params: AddPrimitiveObjectParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .primitive_colorized = params.model,
            },
            .position = params.position,
        });
        errdefer game_object.deinit();

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    pub fn addDirectionalLight(scene: *Scene, params: DirectionalLightParams) !void {
        const light = try scene.allocator.create(DirectionalLight);
        errdefer scene.allocator.destroy(light);
        light.init(params);

        try scene.lights.append(scene.allocator, light);
    }

    pub fn update(scene: *Scene, time: f64) void {
        if (scene.previous_frame_time != 0) {
            const time_passed: f32 = @floatCast(time - scene.previous_frame_time);

            // Time dependant update logic

            scene.spectator_camera.update(time_passed);
        }

        // Time independant update logic

        scene.previous_frame_time = time;
    }
};

pub const AddObjectParams = struct {
    model_id: Engine.LoadedModelId,
    position: [3]f32,
};

pub const AddWindowBoxParams = struct {
    model: *WindowBoxModel,
    position: [3]f32,
};

pub const AddSkyBoxParams = struct {
    model: *SkyBoxModel,
};

pub const AddSkyBoxCubemapParams = struct {
    model: *SkyBoxCubemapModel,
};

pub const AddPrimitiveObjectParams = struct {
    model: *PrimitiveModel,
    position: [3]f32,
};
