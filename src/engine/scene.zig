const std = @import("std");
const zmath = @import("zmath");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;
const GameObjectGroup = @import("./game_object_group.zig").GameObjectGroup;
const WindowBoxModel = @import("./model.zig").WindowBoxModel;
const TerrainHeightMapModel = @import("./model.zig").TerrainHeightMapModel;
const SkyBoxModel = @import("./model.zig").SkyBoxModel;
const SkyBoxCubemapModel = @import("./model.zig").SkyBoxCubemapModel;
const PrimitiveModel = @import("./model.zig").PrimitiveModel;
const Camera = @import("./camera.zig").Camera;
const SpaceTree = @import("./space_tree.zig").SpaceTree;
const SpectatorCamera = @import("./spectator_camera.zig").SpectatorCamera;
const light_module = @import("./light.zig");
const BindGroup = @import("./bind_group.zig").BindGroup;
const DirectionalLight = light_module.DirectionalLight;
const DirectionalLightParams = light_module.DirectionalLightParams;

const INSTANCE_BUFFER_ENTRY_SIZE = 1024;

const InstanceBufferEntry = struct {
    model_matrix: zmath.Mat,
};

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

    // gpu related
    scene_bind_group: BindGroup,

    instance_buffer: struct {
        buffer: []InstanceBufferEntry,
        next_index: u32 = 0,
        handle: zgpu.BufferHandle,
        gpu_buffer: wgpu.Buffer,
    },

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

        const instance_buffer_handle = engine.gctx.createBuffer(.{
            .usage = .{
                .copy_dst = true,
                .storage = true,
            },
            .size = INSTANCE_BUFFER_ENTRY_SIZE * @sizeOf(InstanceBufferEntry),
            // .mapped_at_creation = .true,
        });
        errdefer engine.gctx.destroyResource(instance_buffer_handle);

        const instance_buffer_gpu_buffer = engine.gctx.lookupResource(instance_buffer_handle) orelse return error.BufferIsNotReady;
        // const instance_buffer_gpu_buffer_mapped = instance_buffer_gpu_buffer.getMappedRange(InstanceBufferEntry, 0, INSTANCE_BUFFER_ENTRY_SIZE);

        const instance_buffer = try allocator.alloc(InstanceBufferEntry, INSTANCE_BUFFER_ENTRY_SIZE);

        const scene_bind_group = engine.bind_group_layouts.scene.createBindGroup(
            engine.gctx,
            instance_buffer_handle,
            INSTANCE_BUFFER_ENTRY_SIZE * @sizeOf(InstanceBufferEntry),
        );
        errdefer scene_bind_group.deinit(engine.gctx);

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
            .scene_bind_group = scene_bind_group,
            .instance_buffer = .{
                .buffer = instance_buffer,
                .handle = instance_buffer_handle,
                .gpu_buffer = instance_buffer_gpu_buffer,
            },
        };
        return scene;
    }

    pub fn deinit(scene: *Scene) void {
        const gctx = scene.engine.gctx;

        scene.scene_bind_group.deinit(gctx);

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
            game_object.stopAnimation(gctx);
            scene.allocator.destroy(game_object);
        }
        scene.game_objects.deinit(scene.allocator);

        scene.allocator.free(scene.instance_buffer.buffer);
        gctx.destroyResource(scene.instance_buffer.handle);

        scene.spectator_camera.deinit();
        scene.camera.deinit();
        scene.allocator.destroy(scene.camera);
        scene.allocator.destroy(scene.spectator_camera);
        scene.allocator.destroy(scene);
    }

    pub fn prepareForRendering(scene: *Scene) !void {
        // _ = scene;
        // Before first rendering upload all instances data to the GPU.
        scene.engine.gctx.queue.writeBuffer(
            scene.instance_buffer.gpu_buffer,
            0,
            InstanceBufferEntry,
            scene.instance_buffer.buffer[0..scene.instance_buffer.next_index],
        );
    }

    pub fn addGroup(scene: *Scene) !*GameObjectGroup {
        const new_group = try GameObjectGroup.init(scene.allocator);
        try scene.root_groups.append(scene.allocator, new_group);
        return new_group;
    }

    pub fn addObject(scene: *Scene, params: AddObjectParams) !*GameObject {
        const model_optional = scene.engine.models_hash.get(params.model_id);
        if (model_optional == null) {
            @panic("Invalid model id");
        }

        const model = model_optional.?;
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .regular_model = model,
            },
            .position = params.position,
            .parent = params.parent,
            .space_tree = scene.space_tree,
            .instance_index = scene.instance_buffer.next_index,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.instance_buffer.buffer[game_object.instance_index] = .{
            .model_matrix = zmath.transpose(game_object.getModelMatrix()),
        };

        if (params.animation_name) |animation_name| {
            try game_object.playAnimation(scene.animationContext(), animation_name);
        }

        try scene.game_objects.append(scene.allocator, game_object);
        scene.instance_buffer.next_index += 1;

        return game_object;
    }

    pub fn addTerrainHeightMapObject(scene: *Scene, params: AddTerrainHeightMapObjectParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .terrain_height_map_model = params.model,
            },
            .position = params.position,
            .parent = params.parent,
            .space_tree = scene.space_tree,
            .instance_index = 0, // TODO: actually is not used for terrain height map
        });
        errdefer game_object.deinit(scene.engine.gctx);

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    // TODO: deduplicate with addObject
    pub fn addWindowBoxObject(scene: *Scene, params: AddWindowBoxParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .window_box_model = params.model,
            },
            .position = params.position,
        });
        errdefer game_object.deinit(scene.engine.gctx);

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
        errdefer game_object.deinit(scene.engine.gctx);

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    pub fn addSkyBoxCubemapObject(scene: *Scene, params: AddSkyBoxCubemapParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .skybox_cubemap_model = params.model,
            },
            .position = .{ 0, 0, 0 },
        });
        errdefer game_object.deinit(scene.engine.gctx);

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    pub fn addPrimitiveObject(scene: *Scene, params: AddPrimitiveObjectParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .primitive_colorized = params.model,
            },
            .position = params.position,
            .space_tree = scene.space_tree,
            .parent = null,
            .instance_index = 0, // TODO: actually is not used for primitive object
        });
        errdefer game_object.deinit(scene.engine.gctx);

        try scene.game_objects.append(scene.allocator, game_object);

        return game_object;
    }

    pub fn addDirectionalLight(scene: *Scene, params: DirectionalLightParams) !void {
        const light = try scene.allocator.create(DirectionalLight);
        errdefer scene.allocator.destroy(light);
        light.* = .init(params);

        try scene.lights.append(scene.allocator, light);
    }

    pub fn playObjectAnimation(scene: *Scene, game_object: *GameObject, animation_name: []const u8) !void {
        try game_object.playAnimation(scene.animationContext(), animation_name);
    }

    pub fn switchObjectAnimation(scene: *Scene, game_object: *GameObject, animation_name: []const u8) !void {
        try scene.playObjectAnimation(game_object, animation_name);
    }

    pub fn stopObjectAnimation(scene: *Scene, game_object: *GameObject) void {
        game_object.stopAnimation(scene.engine.gctx);
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

    fn animationContext(scene: *Scene) GameObject.AnimationContext {
        return .{
            .gctx = scene.engine.gctx,
            .bind_group_layout = scene.engine.bind_group_layouts.joints,
            .current_time = @floatCast(scene.engine.time),
        };
    }
};

pub const AddObjectParams = struct {
    model_id: Engine.LoadedModelId,
    position: [3]f32,
    parent: ?*GameObjectGroup,
    animation_name: ?[]const u8 = null,
};

pub const AddTerrainHeightMapObjectParams = struct {
    model: *TerrainHeightMapModel,
    position: [3]f32,
    parent: ?*GameObjectGroup = null,
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
