const std = @import("std");
const zmath = @import("zmath");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const WorldSettings = @import("world_layout.zig").WorldSettings;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const WorldPipelines = @import("pipelines.zig").WorldPipelines;
const Engine = @import("./engine.zig").Engine;
const GameObject = @import("./game_object.zig").GameObject;
const GameObjectGroup = @import("./game_object_group.zig").GameObjectGroup;
const WindowBoxModel = @import("./model.zig").WindowBoxModel;
const TerrainHeightMapModel = @import("./model.zig").TerrainHeightMapModel;
const SkyBoxModel = @import("./model.zig").SkyBoxModel;
const SkyBoxCubemapModel = @import("./model.zig").SkyBoxCubemapModel;
const PrimitiveModel = @import("./model.zig").PrimitiveModel;
const Camera = @import("./camera.zig").Camera;
const Position = @import("world_math.zig").Position;
const SpaceTree = @import("./naive_space_tree.zig").SpaceTree;
const SpectatorCamera = @import("./spectator_camera.zig").SpectatorCamera;
const light_module = @import("./light.zig");
const BindGroup = @import("./bind_group.zig").BindGroup;
const DirectionalLight = light_module.DirectionalLight;
const DirectionalLightParams = light_module.DirectionalLightParams;
const VoxelGrid = @import("./voxel/voxel_grid.zig").VoxelGrid;

const INITIAL_OBJECT_CAPACITY = 64;

pub const InstanceBufferEntry = @import("chunk_transform.zig").ChunkTransform;

pub const Scene = struct {
    /// Immutable after creation; all scene coordinate consumers share this layout.
    layout: *const WorldLayout,
    /// Borrowed from the engine cache; one reference for this scene's lifetime.
    pipelines: *const WorldPipelines,
    engine: *Engine,
    allocator: std.mem.Allocator,
    game_objects: std.ArrayList(*GameObject) = undefined,
    /// Owns every scene group, including parented groups.
    groups: std.ArrayList(*GameObjectGroup) = .empty,
    is_drawing: bool = false,
    /// Configure before drawing. Future point/spot lights will have separate collections.
    directional_light: ?DirectionalLight = null,
    skybox_object: ?*GameObject,
    space_tree: *SpaceTree(GameObject),
    voxel_grid: *VoxelGrid,
    voxel_bind_group: BindGroup,
    camera: *Camera,
    spectator_camera: *SpectatorCamera,
    /// Applications can drive the camera themselves while retaining the debug controller.
    spectator_enabled: bool = true,
    previous_frame_time: f64,

    // gpu related
    scene_bind_group: BindGroup,

    instance_buffer: struct {
        buffer: []InstanceBufferEntry,
        next_index: u32 = 0,
        max_capacity: u32,
        /// Reserved alongside buffer capacity, so deletion never allocates.
        free_indices: std.ArrayList(u32) = .empty,
        handle: zgpu.BufferHandle,
        gpu_buffer: wgpu.Buffer,
        outdated_indices: std.DynamicBitSetUnmanaged = undefined,
    },

    pub fn init(
        engine: *Engine,
        allocator: std.mem.Allocator,
        settings: WorldSettings,
    ) !*Scene {
        const validated_layout = try WorldLayout.init(settings);
        const layout = try allocator.create(WorldLayout);
        errdefer allocator.destroy(layout);
        layout.* = validated_layout;
        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);

        scene.layout = layout;
        const pipelines = try engine.world_pipeline_cache.acquire(&engine.bind_group_layouts, scene.layout);
        errdefer engine.world_pipeline_cache.release(pipelines);

        const space_tree = try SpaceTree(GameObject).init(allocator);
        errdefer space_tree.deinit();

        const camera = try allocator.create(Camera);
        errdefer allocator.destroy(camera);
        camera.* = Camera.init(scene.layout, engine.aspect_ratio);

        const spectator_camera = try allocator.create(SpectatorCamera);
        errdefer allocator.destroy(spectator_camera);
        // @ptrCast to dismiss Engine generic type parameter, using `void` as a generic type parameter
        // because SpectatorCamera doesn't need to know about the Engine type
        spectator_camera.* = SpectatorCamera.init(camera, @ptrCast(engine.input_controller));

        var limits: wgpu.SupportedLimits = .{};
        if (!engine.gctx.device.getLimits(&limits)) return error.DeviceLimitsUnavailable;
        const max_capacity: u32 = @intCast(@min(
            @min(limits.limits.max_buffer_size, limits.limits.max_storage_buffer_binding_size) / @sizeOf(InstanceBufferEntry),
            @min(std.math.maxInt(u32), std.math.maxInt(usize) / @sizeOf(InstanceBufferEntry)),
        ));
        if (max_capacity == 0) return error.SceneCapacityReached;
        const capacity: usize = @min(INITIAL_OBJECT_CAPACITY, max_capacity);
        const instance_buffer_handle = engine.gctx.createBuffer(.{
            .usage = .{
                .copy_dst = true,
                .storage = true,
                .copy_src = true,
            },
            .size = capacity * @sizeOf(InstanceBufferEntry),
        });
        errdefer engine.gctx.destroyResource(instance_buffer_handle);

        const instance_buffer_gpu_buffer = engine.gctx.lookupResource(instance_buffer_handle) orelse return error.BufferIsNotReady;
        const buffer = try allocator.alloc(InstanceBufferEntry, capacity);
        errdefer allocator.free(buffer);
        // Upload ranges may span unused slots; keep them initialized.
        @memset(buffer, std.mem.zeroes(InstanceBufferEntry));

        var outdated_indices = try std.DynamicBitSetUnmanaged.initEmpty(allocator, capacity);
        errdefer outdated_indices.deinit(allocator);
        var free_indices = try std.ArrayList(u32).initCapacity(allocator, capacity);
        errdefer free_indices.deinit(allocator);

        const scene_bind_group = engine.bind_group_layouts.scene.createBindGroup(
            engine.gctx,
            instance_buffer_handle,
            capacity * @sizeOf(InstanceBufferEntry),
        );
        errdefer scene_bind_group.deinit(engine.gctx);

        const voxel_grid = try VoxelGrid.init(allocator, engine.gctx);
        errdefer voxel_grid.deinit(engine.gctx);

        const voxel_bind_group = engine.bind_group_layouts.voxel.createBindGroup(
            engine.gctx,
            voxel_grid.gpu_chunk_info_buffer,
            voxel_grid.gpu_block_buffer,
        );
        errdefer voxel_bind_group.deinit(engine.gctx);

        const game_objects = try std.ArrayList(*GameObject).initCapacity(allocator, capacity);

        scene.* = .{
            .layout = layout,
            .pipelines = pipelines,
            .engine = engine,
            .allocator = allocator,
            .game_objects = game_objects,
            .groups = .empty,
            .directional_light = null,
            .skybox_object = null,
            .space_tree = space_tree,
            .voxel_grid = voxel_grid,
            .voxel_bind_group = voxel_bind_group,
            .camera = camera,
            .spectator_camera = spectator_camera,
            .previous_frame_time = 0,
            .scene_bind_group = scene_bind_group,
            .instance_buffer = .{
                .buffer = buffer,
                .handle = instance_buffer_handle,
                .gpu_buffer = instance_buffer_gpu_buffer,
                .max_capacity = max_capacity,
                .free_indices = free_indices,
                .outdated_indices = outdated_indices,
            },
        };
        engine.live_scene_count += 1;
        return scene;
    }

    pub fn deinit(scene: *Scene) void {
        std.debug.assert(!scene.is_drawing);
        const gctx = scene.engine.gctx;
        std.debug.assert(scene.engine.live_scene_count > 0);
        scene.engine.live_scene_count -= 1;
        if (scene.engine.active_scene == scene) scene.engine.active_scene = null;

        // Objects detach from their parent during deinit, while groups and the
        // visibility index are still alive.
        if (scene.skybox_object) |skybox_object| skybox_object.deinit(gctx);

        scene.scene_bind_group.deinit(gctx);

        scene.voxel_bind_group.deinit(gctx);
        scene.voxel_grid.deinit(gctx);

        for (scene.game_objects.items) |game_object| game_object.deinit(gctx);
        scene.game_objects.deinit(scene.allocator);
        scene.space_tree.deinit();

        while (scene.groups.pop()) |group| group.deinit();
        scene.groups.deinit(scene.allocator);

        scene.instance_buffer.free_indices.deinit(scene.allocator);
        scene.instance_buffer.outdated_indices.deinit(scene.allocator);
        scene.allocator.free(scene.instance_buffer.buffer);
        gctx.destroyResource(scene.instance_buffer.handle);

        scene.spectator_camera.deinit();
        scene.camera.deinit();
        scene.allocator.destroy(scene.camera);
        scene.allocator.destroy(scene.spectator_camera);
        scene.engine.world_pipeline_cache.release(scene.pipelines);
        scene.allocator.destroy(@constCast(scene.layout));
        scene.allocator.destroy(scene);
    }

    pub fn prepareForRendering(scene: *Scene) !void {
        try scene.checkMutationAllowed();
        // Before first rendering upload all instances data to the GPU.
        if (scene.instance_buffer.next_index > 0) scene.engine.gctx.queue.writeBuffer(
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
        try scene.checkMutationAllowed();
        const new_group = try GameObjectGroup.init(scene.allocator);
        errdefer new_group.deinit();
        try scene.groups.append(scene.allocator, new_group);
        new_group.scene = scene;
        return new_group;
    }

    /// Mutations are synchronous on the application thread, before drawing.
    pub fn checkMutationAllowed(scene: *const Scene) error{SceneMutationDuringDraw}!void {
        if (scene.is_drawing) return error.SceneMutationDuringDraw;
    }

    /// Invalidates the object's borrowed pointer immediately. Models stay engine-owned.
    pub fn removeObject(scene: *Scene, object: *GameObject) !void {
        try scene.checkMutationAllowed();
        const index = std.mem.indexOfScalar(*GameObject, scene.game_objects.items, object) orelse return error.ObjectNotInScene;
        const instance_index = object.instance_index.?;
        _ = scene.game_objects.swapRemove(index);
        object.deinit(scene.engine.gctx);
        scene.releaseInstanceSlot(instance_index);
    }

    /// Deletes current transform descendants; reparented-out children survive.
    pub fn removeGroup(scene: *Scene, group: *GameObjectGroup) !void {
        try scene.checkMutationAllowed();
        if (std.mem.indexOfScalar(*GameObjectGroup, scene.groups.items, group) == null) return error.GroupNotInScene;
        while (group.children.items.len > 0) {
            switch (group.children.items[group.children.items.len - 1]) {
                .game_object => |object| try scene.removeObject(object),
                .group => |child| try scene.removeGroup(child),
            }
        }
        // Descendant removals use swap removal, so find this group again.
        const index = std.mem.indexOfScalar(*GameObjectGroup, scene.groups.items, group).?;
        _ = scene.groups.swapRemove(index);
        group.deinit();
    }

    fn reserveInstanceSlot(scene: *Scene, parent: ?*GameObjectGroup) !u32 {
        try scene.checkMutationAllowed();
        if (parent) |group| {
            if (group.scene != scene) return error.GroupBelongsToAnotherScene;
        }
        if (scene.instance_buffer.free_indices.items.len == 0 and scene.instance_buffer.next_index == scene.instance_buffer.max_capacity) return error.SceneCapacityReached;
        try scene.game_objects.ensureUnusedCapacity(scene.allocator, 1);
        try scene.space_tree.objects.ensureUnusedCapacity(scene.allocator, 1);
        // Draw preparation must not encounter a fixed capacity or allocate midway
        // through a frame. Reserve space for all three shadow lists and the camera.
        try scene.engine.reserveObjectDrawCapacity(scene.game_objects.items.len + 1);
        if (scene.instance_buffer.free_indices.pop()) |index| return index;
        const index = scene.instance_buffer.next_index;
        if (index == scene.instance_buffer.buffer.len) try scene.growInstanceBuffer();
        scene.instance_buffer.next_index += 1;
        return index;
    }

    fn releaseInstanceSlot(scene: *Scene, index: u32) void {
        scene.instance_buffer.outdated_indices.unset(index);
        scene.instance_buffer.buffer[index] = std.mem.zeroes(InstanceBufferEntry);
        scene.instance_buffer.free_indices.appendAssumeCapacity(index);
    }

    fn growInstanceBuffer(scene: *Scene) !void {
        const old_capacity = scene.instance_buffer.buffer.len;
        const capacity = @min(old_capacity * 2, scene.instance_buffer.max_capacity);
        const buffer = try scene.allocator.alloc(InstanceBufferEntry, capacity);
        errdefer scene.allocator.free(buffer);
        @memcpy(buffer[0..old_capacity], scene.instance_buffer.buffer);
        @memset(buffer[old_capacity..], std.mem.zeroes(InstanceBufferEntry));
        var dirty = try scene.instance_buffer.outdated_indices.clone(scene.allocator);
        errdefer dirty.deinit(scene.allocator);
        try dirty.resize(scene.allocator, capacity, false);
        try scene.instance_buffer.free_indices.ensureTotalCapacity(scene.allocator, capacity);

        const gctx = scene.engine.gctx;
        const handle = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .copy_src = true, .storage = true },
            .size = capacity * @sizeOf(InstanceBufferEntry),
        });
        errdefer gctx.destroyResource(handle);
        const gpu_buffer = gctx.lookupResource(handle) orelse return error.BufferIsNotReady;
        const binding = scene.engine.bind_group_layouts.scene.createBindGroup(gctx, handle, capacity * @sizeOf(InstanceBufferEntry));

        // Seed unchanged transforms too. Dirty objects are recomputed before draw.
        gctx.queue.writeBuffer(gpu_buffer, 0, InstanceBufferEntry, buffer[0..scene.instance_buffer.next_index]);
        scene.scene_bind_group.deinit(gctx);
        // Release rather than destroy: previously submitted commands can still
        // hold the old buffer while the next frame uses its replacement.
        gctx.releaseResource(scene.instance_buffer.handle);
        scene.allocator.free(scene.instance_buffer.buffer);
        scene.instance_buffer.outdated_indices.deinit(scene.allocator);
        scene.instance_buffer.buffer = buffer;
        scene.instance_buffer.outdated_indices = dirty;
        scene.instance_buffer.handle = handle;
        scene.instance_buffer.gpu_buffer = gpu_buffer;
        scene.scene_bind_group = binding;
    }

    pub fn addObject(scene: *Scene, params: AddObjectParams) !*GameObject {
        try scene.checkMutationAllowed();
        const model = scene.engine.models_hash.get(params.model_id) orelse return error.InvalidModelId;
        const instance_index = try scene.reserveInstanceSlot(params.parent);
        errdefer scene.releaseInstanceSlot(instance_index);
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

        scene.instance_buffer.buffer[instance_index] = InstanceBufferEntry.init(scene.layout, game_object.getModelMatrix());

        if (params.animation_name) |animation_name| {
            try game_object.playAnimation(scene.animationContext(), animation_name);
        }

        scene.game_objects.appendAssumeCapacity(game_object);
        return game_object;
    }

    pub fn addTerrainHeightMapObject(scene: *Scene, params: AddTerrainHeightMapObjectParams) !*GameObject {
        const instance_index = try scene.reserveInstanceSlot(params.parent);
        errdefer scene.releaseInstanceSlot(instance_index);
        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .model = .{
                .terrain_height_map_model = params.model,
            },
            .position = params.position,
            .parent = params.parent,
            .instance_index = instance_index,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.instance_buffer.buffer[instance_index] = InstanceBufferEntry.init(scene.layout, game_object.getModelMatrix());
        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    // TODO: deduplicate with addObject
    pub fn addWindowBoxObject(scene: *Scene, params: AddWindowBoxParams) !*GameObject {
        const instance_index = try scene.reserveInstanceSlot(null);
        errdefer scene.releaseInstanceSlot(instance_index);
        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .parent = null,
            .instance_index = instance_index,
            .model = .{
                .window_box_model = params.model,
            },
            .position = params.position,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.instance_buffer.buffer[instance_index] = InstanceBufferEntry.init(scene.layout, game_object.getModelMatrix());
        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    pub fn addSkyBoxObject(scene: *Scene, params: AddSkyBoxParams) !*GameObject {
        const instance_index = try scene.reserveInstanceSlot(null);
        errdefer scene.releaseInstanceSlot(instance_index);
        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .parent = null,
            .instance_index = instance_index,
            .model = .{
                .skybox_model = params.model,
            },
            .position = .{ 0, 0, 0 },
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.instance_buffer.buffer[instance_index] = InstanceBufferEntry.init(scene.layout, game_object.getModelMatrix());
        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    pub fn setSkyBoxCubemapObject(scene: *Scene, params: AddSkyBoxCubemapParams) !*GameObject {
        try scene.checkMutationAllowed();
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
        const instance_index = try scene.reserveInstanceSlot(null);
        errdefer scene.releaseInstanceSlot(instance_index);
        const game_object = try GameObject.init(scene.allocator, .{
            .scene = scene,
            .model = .{
                .primitive_colorized = params.model,
            },
            .position = params.position,
            .parent = null,
            .instance_index = instance_index,
        });
        errdefer game_object.deinit(scene.engine.gctx);

        scene.instance_buffer.buffer[instance_index] = InstanceBufferEntry.init(scene.layout, game_object.getModelMatrix());
        scene.game_objects.appendAssumeCapacity(game_object);

        return game_object;
    }

    /// A scene supports one directional light; a second addition leaves it unchanged.
    pub fn addDirectionalLight(scene: *Scene, params: DirectionalLightParams) error{DirectionalLightAlreadyExists}!void {
        if (scene.directional_light != null) return error.DirectionalLightAlreadyExists;
        scene.directional_light = .init(params);
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

            if (scene.spectator_enabled and scene.engine.input_controller.focused and
                !scene.engine.input_controller.focus_changed)
            {
                scene.spectator_camera.update(time_passed);
            }
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
    position: Position,
    parent: ?*GameObjectGroup,
    animation_name: ?[]const u8 = null,
};

pub const AddTerrainHeightMapObjectParams = struct {
    model: *TerrainHeightMapModel,
    position: Position,
    parent: ?*GameObjectGroup = null,
};

pub const AddWindowBoxParams = struct {
    model: *WindowBoxModel,
    position: Position,
};

pub const AddSkyBoxParams = struct {
    model: *SkyBoxModel,
};

pub const AddSkyBoxCubemapParams = struct {
    model: *SkyBoxCubemapModel,
};

pub const AddPrimitiveObjectParams = struct {
    model: *PrimitiveModel,
    position: Position,
};
