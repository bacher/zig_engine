const std = @import("std");
const zmath = @import("zmath");

const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;
const Camera = @import("./camera.zig").Camera;

pub const Scene = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject),
    camera: *Camera,
    previous_frame_time: f32,

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
            .previous_frame_time = 0,
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

    pub fn update(scene: *Scene, time: f32) void {
        if (scene.previous_frame_time != 0) {
            const time_passed = time - scene.previous_frame_time;

            // Time dependant update logic

            const input_controller = scene.engine.input_controller;

            var direction = zmath.Vec{ 0, 0, 0, 1 };
            const step = 1 * time_passed;

            if (input_controller.isKeyPressed(.w)) {
                direction[2] -= step;
            }
            if (input_controller.isKeyPressed(.s)) {
                direction[2] += step;
            }
            if (input_controller.isKeyPressed(.a)) {
                direction[0] += step;
            }
            if (input_controller.isKeyPressed(.d)) {
                direction[0] -= step;
            }

            if (direction[0] != 0 or direction[2] != 0) {
                if (direction[0] != 0 and direction[2] != 0) {
                    direction[0] *= std.math.sqrt1_2;
                    direction[2] *= std.math.sqrt1_2;
                }

                // This is correct version, but we can skip inversing by chaning
                // order of multiplying because in case of only rotation:
                // mat * vec == vec * inverse(mat)
                //
                // const aligned_direction = zmath.mul(
                //     direction,
                //     zmath.inverse(scene.camera.camera_to_view),
                // );

                const aligned_direction = zmath.mul(
                    scene.camera.camera_to_view,
                    direction,
                );

                scene.camera.updatePosition(zmath.Vec{
                    scene.camera.position[0] + aligned_direction[0],
                    scene.camera.position[1] + aligned_direction[1],
                    scene.camera.position[2] + aligned_direction[2],
                    scene.camera.position[3],
                });
            }
        }

        // Time independant update logic

        scene.previous_frame_time = time;
    }
};

pub const AddObjectParams = struct {
    model_id: Engine.LoadedModelId,
    position: [3]f32,
};
