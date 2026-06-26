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
const MAX_OBJECTS_COUNT = 4096;

pub const InstanceBufferEntry = extern struct {
    model_matrix: zmath.Mat,
};

pub const Scene = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject) = undefined,
    root_groups: std.ArrayList(*GameObjectGroup) = .empty,
    // TODO: Maybe store light as a value instead of a pointer?
    lights: std.ArrayList(*DirectionalLight) = .empty,
    skybox_object: ?*GameObject,
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
        // outdated_indices: std.ArrayList(u32) = .empty,
        outdated_indices: std.DynamicBitSetUnmanaged = undefined,
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

        const buffer = try allocator.alloc(InstanceBufferEntry, INSTANCE_BUFFER_ENTRY_SIZE);
        errdefer allocator.free(buffer);

        const outdated_indices = try std.DynamicBitSetUnmanaged.initEmpty(allocator, MAX_OBJECTS_COUNT);
        errdefer outdated_indices.deinit(allocator);

        const scene_bind_group = engine.bind_group_layouts.scene.createBindGroup(
            engine.gctx,
            instance_buffer_handle,
            INSTANCE_BUFFER_ENTRY_SIZE * @sizeOf(InstanceBufferEntry),
        );
        errdefer scene_bind_group.deinit(engine.gctx);

        scene.* = .{
            .engine = engine,
            .allocator = allocator,
            .game_objects = std.ArrayList(*GameObject).initCapacity(allocator, MAX_OBJECTS_COUNT) catch @panic("Failed to initialize game objects buffer"),
            .root_groups = .empty,
            .lights = .empty,
            .skybox_object = null,
            .space_tree = space_tree,
            .camera = camera,
            .spectator_camera = spectator_camera,
            .previous_frame_time = 0,
            .scene_bind_group = scene_bind_group,
            .instance_buffer = .{
                .buffer = buffer,
                .handle = instance_buffer_handle,
                .gpu_buffer = instance_buffer_gpu_buffer,
                .outdated_indices = outdated_indices,
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

        scene.instance_buffer.outdated_indices.deinit(scene.allocator);
        scene.allocator.free(scene.instance_buffer.buffer);
        gctx.destroyResource(scene.instance_buffer.handle);

        scene.spectator_camera.deinit();
        scene.camera.deinit();
        if (scene.skybox_object) |skybox_object| skybox_object.deinit(gctx);
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

    pub fn updateInstanceBuffer(scene: *Scene, instance_index: u32) void {
        scene.instance_buffer.outdated_indices.set(instance_index);
    }

    pub fn addGroup(scene: *Scene) !*GameObjectGroup {
        const new_group = try GameObjectGroup.init(scene.allocator);
        try scene.root_groups.append(scene.allocator, new_group);
        return new_group;
    }

    pub fn addObject(scene: *Scene, params: AddObjectParams) !*GameObject {
        try scene.checkMaxObjectsCount();

        const model_optional = scene.engine.models_hash.get(params.model_id);
        if (model_optional == null) {
            @panic("Invalid model id");
        }

        const model = model_optional.?;
        const instance_index = scene.instance_buffer.next_index;
        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .model = .{
                .regular_model = model,
            },
            .position = params.position,
            .parent = params.parent,
            .instance_index = instance_index,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.instance_buffer.buffer[instance_index] = .{
            .model_matrix = game_object.getModelMatrix(),
        };

        if (params.animation_name) |animation_name| {
            try game_object.playAnimation(scene.animationContext(), animation_name);
        }

        scene.game_objects.appendAssumeCapacity(game_object);
        scene.instance_buffer.next_index += 1;

        return game_object;
    }

    pub fn checkMaxObjectsCount(scene: *Scene) !void {
        if (scene.game_objects.items.len >= MAX_OBJECTS_COUNT) {
            return error.MaxObjectsCountReached;
        }
    }

    pub fn addTerrainHeightMapObject(scene: *Scene, params: AddTerrainHeightMapObjectParams) !*GameObject {
        try scene.checkMaxObjectsCount();

        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .model = .{
                .terrain_height_map_model = params.model,
            },
            .position = params.position,
            .parent = params.parent,
            .instance_index = null,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    // TODO: deduplicate with addObject
    pub fn addWindowBoxObject(scene: *Scene, params: AddWindowBoxParams) !*GameObject {
        try scene.checkMaxObjectsCount();

        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .window_box_model = params.model,
            },
            .position = params.position,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    pub fn addSkyBoxObject(scene: *Scene, params: AddSkyBoxParams) !*GameObject {
        try scene.checkMaxObjectsCount();

        const game_object = try GameObject.init(scene.allocator, .{
            .model = .{
                .skybox_model = params.model,
            },
            .position = .{ 0, 0, 0 },
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    pub fn setSkyBoxCubemapObject(scene: *Scene, params: AddSkyBoxCubemapParams) !*GameObject {
        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .model = .{
                .skybox_cubemap_model = params.model,
            },
            .position = .{ 0, 0, 0 },
            .parent = null,
            .instance_index = null,
            .skip_space_tree = true,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        if (scene.skybox_object) |current_skybox_object| {
            current_skybox_object.deinit(scene.engine.gctx);
        }

        scene.skybox_object = game_object;

        return game_object;
    }

    pub fn addPrimitiveObject(scene: *Scene, params: AddPrimitiveObjectParams) !*GameObject {
        try scene.checkMaxObjectsCount();

        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .model = .{
                .primitive_colorized = params.model,
            },
            .position = params.position,
            .parent = null,
            .instance_index = null,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.game_objects.appendAssumeCapacity(game_object);

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
