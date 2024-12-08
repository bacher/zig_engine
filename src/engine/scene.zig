const std = @import("std");

const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;

pub const Scene = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject),

    pub fn init(engine: *Engine, allocator: std.mem.Allocator) !*Scene {
        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);

        const game_objects = std.ArrayList(*GameObject).init(allocator);
        errdefer game_objects.deinit();

        scene.* = .{
            .engine = engine,
            .allocator = allocator,
            .game_objects = game_objects,
        };
        return scene;
    }

    pub fn deinit(scene: *Scene) void {
        for (scene.game_objects.items) |game_object| {
            scene.allocator.destroy(game_object);
        }
        scene.game_objects.deinit();
        scene.allocator.destroy(scene);
    }

    pub fn addObject(scene: *Scene, params: AddObjectParams) !*GameObject {
        const model = scene.engine.models_hash.get(params.model_id);
        // var iterator = scene.engine.models_hash.iterator();
        // const model = iterator.next().?.value_ptr;

        if (model == null) {
            return error.InvalidModelId;
        }

        const game_object = try GameObject.init(scene.allocator, .{
            .model = &model.?,
            .position = params.position,
        });
        errdefer game_object.deinit();

        try scene.game_objects.append(game_object);

        return game_object;
    }
};

pub const AddObjectParams = struct {
    model_id: Engine.LoadedModelId,
    position: [3]f32,
};
