const std = @import("std");

const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;
const Camera = @import("./camera.zig").Camera;

pub const Scene = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject),
    camera: *Camera,

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

        scene.* = .{
            .engine = engine,
            .allocator = allocator,
            .game_objects = game_objects,
            .camera = camera,
        };
        return scene;
    }

    pub fn deinit(scene: *Scene) void {
        for (scene.game_objects.items) |game_object| {
            scene.allocator.destroy(game_object);
        }
        scene.game_objects.deinit();
        scene.allocator.destroy(scene.camera);
        scene.allocator.destroy(scene);
    }

    pub fn addObject(scene: *Scene, params: AddObjectParams) !*GameObject {
        if (scene.engine.models_hash.get(params.model_id)) |model| {
            const game_object = try GameObject.init(scene.allocator, .{
                .model = model,
                .position = params.position,
            });
            errdefer game_object.deinit();

            try scene.game_objects.append(game_object);

            return game_object;
        } else {
            return error.InvalidModelId;
        }
    }
};

pub const AddObjectParams = struct {
    model_id: Engine.LoadedModelId,
    position: [3]f32,
};
