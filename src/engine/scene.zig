const std = @import("std");
const zmath = @import("zmath");

const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;
const WindowBoxModel = @import("./model.zig").WindowBoxModel;
const Camera = @import("./camera.zig").Camera;
const SpectatorCamera = @import("./spectator_camera.zig").SpectatorCamera;

pub const Scene = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject),
    camera: *Camera,
    spectator_camera: *SpectatorCamera,
    previous_frame_time: f64,

    pub fn init(
        engine: *Engine,
        allocator: std.mem.Allocator,
        screen_width: u32,
        screen_height: u32,
    ) !*Scene {
        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);

        const game_objects = std.ArrayList(*GameObject).init(allocator);
        errdefer game_objects.deinit();

        const camera = try allocator.create(Camera);
        errdefer allocator.destroy(camera);
        camera.* = Camera.init(screen_width, screen_height);

        const spectator_camera = try allocator.create(SpectatorCamera);
        errdefer allocator.destroy(spectator_camera);
        spectator_camera.* = SpectatorCamera.init(camera, engine.input_controller);

        scene.* = .{
            .engine = engine,
            .allocator = allocator,
            .game_objects = game_objects,
            .camera = camera,
            .spectator_camera = spectator_camera,
            .previous_frame_time = 0,
        };
        return scene;
    }

    pub fn deinit(scene: *Scene) void {
        for (scene.game_objects.items) |game_object| {
            scene.allocator.destroy(game_object);
        }
        scene.game_objects.deinit();
        scene.spectator_camera.deinit();
        scene.camera.deinit();
        scene.allocator.destroy(scene.camera);
        scene.allocator.destroy(scene.spectator_camera);
        scene.allocator.destroy(scene);
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

            try scene.game_objects.append(game_object);

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

        try scene.game_objects.append(game_object);

        return game_object;
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
