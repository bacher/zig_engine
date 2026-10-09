const layout = @import("test_world.zig").layout;
const std = @import("std");
const zmath = @import("zmath");
const GameObjectGroup = @import("game_object_group.zig").GameObjectGroup;
const GameObject = @import("game_object.zig").GameObject;
const Scene = @import("scene.zig").Scene;
const SpaceTree = @import("naive_space_tree.zig").SpaceTree;
const PrimitiveModel = @import("model.zig").PrimitiveModel;
const ChunkTransform = @import("chunk_transform.zig").ChunkTransform;
const world_math = @import("world_math.zig");

fn expectPosition(expected: world_math.Position, matrix: world_math.Mat) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], matrix[3][i], 0.000001);
}

test "nested groups inherit f64 translation rotation and scale without changing local positions" {
    const root = try GameObjectGroup.init(std.testing.allocator);
    defer root.deinit_recursively();
    root.setPosition(.{ 1e9, -1e9, 1e9 });
    root.setRotation(zmath.quatFromNormAxisAngle(.{ 0, 0, 1, 0 }, std.math.pi / 2.0));
    root.setScale(2);
    const child = try root.addGroup();
    try std.testing.expectEqual(root, child.parent.?);
    try expectPosition(.{ 1e9, -1e9, 1e9 }, child.aggregated_matrix);
    child.setPosition(.{ 0.125, 0.25, 0.5 });
    const grandchild = try child.addGroup();
    grandchild.setPosition(.{ 0.25, -0.125, 0.5 });
    try expectPosition(.{ 1e9 - 0.25, -1e9 + 0.75, 1e9 + 2 }, grandchild.aggregated_matrix);
    child.setScale(0.5);
    try expectPosition(.{ 1e9 - 0.375, -1e9 + 0.5, 1e9 + 1.5 }, grandchild.aggregated_matrix);
    root.setPosition(.{ 1e9 + 0.03125, -1e9, 1e9 });
    try expectPosition(.{ 1e9 - 0.34375, -1e9 + 0.5, 1e9 + 1.5 }, grandchild.aggregated_matrix);
    try std.testing.expectEqual(world_math.Position{ 0.125, 0.25, 0.5 }, child.position);
    try std.testing.expectEqual(world_math.Position{ 0.25, -0.125, 0.5 }, grandchild.position);
}

test "objects supplied a parent receive updates and retain sub-f32-world offsets on upload" {
    const allocator = std.testing.allocator;
    var fixture: SceneFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const scene = &fixture.scene;
    const root = try scene.addGroup();
    const child = try root.addGroup();
    root.setPosition(.{ 1e9, -1e9, 1e9 });
    child.setPosition(.{ 0.125, 0.25, 0.5 });
    var model: PrimitiveModel = undefined; // No geometry or GPU is needed for transforms.
    const object = try GameObject.init(allocator, .{
        .scene = scene,
        .position = .{ 0.015625, 0.03125, 0.0625 },
        .model = .{ .primitive_colorized = &model },
        .parent = child,
        .instance_index = 0,
    });
    defer object.deinit(undefined);
    try std.testing.expectEqual(1, child.children.items.len);
    try child.addObject(object); // Reattaching must not duplicate notifications.
    try std.testing.expectEqual(1, child.children.items.len);
    scene.instance_buffer.outdated_indices.unset(0);
    root.setPosition(.{ 1e9 + 0.5, -1e9, 1e9 });
    try std.testing.expect(scene.instance_buffer.outdated_indices.isSet(0));
    try expectPosition(.{ 1e9 + 0.640625, -1e9 + 0.28125, 1e9 + 0.5625 }, object.aggregated_matrix);
    const upload = ChunkTransform.init(&layout, object.getModelMatrix());
    const relative = upload.relativeTo(&layout, layout.getChunkCoords(.{ 1e9, -1e9, 1e9 }));
    inline for (0..3) |i| try std.testing.expectApproxEqAbs((@as([3]f32, .{ 0.640625, 0.28125, 0.5625 }))[i], relative[3][i], 0.000001);
    try std.testing.expectEqual(world_math.Position{ 0.015625, 0.03125, 0.0625 }, object.position);

    object.setParent(root);
    try std.testing.expectEqual(0, child.children.items.len);
    child.setPosition(.{ 500, 500, 500 });
    try expectPosition(.{ 1e9 + 0.515625, -1e9 + 0.03125, 1e9 + 0.0625 }, object.aggregated_matrix);
    object.setParent(null);
    root.setPosition(.{ 0, 0, 0 });
    try expectPosition(object.position, object.aggregated_matrix);
}

test "reparented groups follow only their current parent and preserve local transforms" {
    const first = try GameObjectGroup.init(std.testing.allocator);
    defer first.deinit_recursively();
    const second = try GameObjectGroup.init(std.testing.allocator);
    defer second.deinit_recursively();
    const child = try first.addGroup();
    child.setPosition(.{ 0.125, 0, 0 });
    second.setPosition(.{ 1e9, 0, 0 });
    child.setParent(second);
    try std.testing.expectEqual(0, first.children.items.len);
    try std.testing.expectEqual(1, second.children.items.len);
    first.setPosition(.{ -1e9, 0, 0 });
    try expectPosition(.{ 1e9 + 0.125, 0, 0 }, child.aggregated_matrix);
    second.setPosition(.{ 1e9 + 0.25, 0, 0 });
    try expectPosition(.{ 1e9 + 0.375, 0, 0 }, child.aggregated_matrix);
    child.setParent(null);
    try expectPosition(.{ 0.125, 0, 0 }, child.aggregated_matrix);
    try std.testing.expectEqual(0, second.children.items.len);
}

test "object destruction borrows a terrain model shared by other objects" {
    const allocator = std.testing.allocator;
    var fixture: SceneFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const scene = &fixture.scene;
    const group = try scene.addGroup();
    var terrain: @import("model.zig").TerrainHeightMapModel = undefined;
    const first = try GameObject.init(allocator, .{
        .scene = scene,
        .model = .{ .terrain_height_map_model = &terrain },
        .position = .{ 0, 0, 0 },
        .parent = group,
        .instance_index = null,
        .skip_space_tree = true,
    });
    const second = try GameObject.init(allocator, .{
        .scene = scene,
        .model = .{ .terrain_height_map_model = &terrain },
        .position = .{ 1, 0, 0 },
        .parent = group,
        .instance_index = null,
        .skip_space_tree = true,
    });
    defer second.deinit(undefined);
    first.deinit(undefined);
    try std.testing.expectEqual(@as(usize, 1), group.children.items.len);
    try std.testing.expect(second.model.terrain_height_map_model == &terrain);
    second.setPosition(.{ 2, 0, 0 });
}

/// Real object/group APIs with CPU instance storage; these tests never grow or
/// access GPU resources. Headless tests exercise growth and animated instances.
const SceneFixture = struct {
    engine: @import("engine.zig").Engine,
    scene: Scene,
    model: PrimitiveModel = undefined,

    fn init(self: *SceneFixture) !void {
        const allocator = std.testing.allocator;
        self.engine = undefined;
        self.engine.allocator = allocator;
        self.engine.gctx = undefined;
        self.engine.temp_buffers = .{
            .visible_objects_lists = .empty,
            .visible_objects_lists_chunks = .empty,
            .regular_objects = .empty,
            .skinned_objects = .empty,
            .wireframe_objects = .empty,
            .rest_objects = .empty,
        };
        const tree = try SpaceTree(GameObject).init(allocator);
        errdefer tree.deinit();
        const buffer = try allocator.alloc(ChunkTransform, 8);
        errdefer allocator.free(buffer);
        @memset(buffer, std.mem.zeroes(ChunkTransform));
        var dirty = try std.DynamicBitSetUnmanaged.initEmpty(allocator, 8);
        errdefer dirty.deinit(allocator);
        const free = try std.ArrayList(u32).initCapacity(allocator, 8);
        self.scene = undefined;
        self.scene.layout = &layout;
        self.scene.engine = &self.engine;
        self.scene.allocator = allocator;
        self.scene.is_drawing = false;
        self.scene.groups = .empty;
        self.scene.game_objects = .empty;
        self.scene.space_tree = tree;
        self.scene.instance_buffer = .{
            .buffer = buffer,
            .max_capacity = 8,
            .free_indices = free,
            .outdated_indices = dirty,
            .handle = undefined,
            .gpu_buffer = undefined,
        };
    }

    fn add(self: *SceneFixture, parent: ?*GameObjectGroup) !*GameObject {
        const object = try self.scene.addPrimitiveObject(.{ .model = &self.model, .position = .{ 1, 2, 3 } });
        object.setParent(parent);
        return object;
    }

    fn deinit(self: *SceneFixture) void {
        const allocator = std.testing.allocator;
        for (self.scene.game_objects.items) |object| object.deinit(undefined);
        self.scene.game_objects.deinit(allocator);
        while (self.scene.groups.pop()) |group| group.deinit();
        self.scene.groups.deinit(allocator);
        self.scene.space_tree.deinit();
        self.scene.instance_buffer.outdated_indices.deinit(allocator);
        self.scene.instance_buffer.free_indices.deinit(allocator);
        allocator.free(self.scene.instance_buffer.buffer);
        inline for (.{ "visible_objects_lists", "visible_objects_lists_chunks", "regular_objects", "skinned_objects", "wireframe_objects", "rest_objects" }) |name| {
            @field(self.engine.temp_buffers, name).deinit(allocator);
        }
    }
};

test "gameplay removal reuses slots indefinitely and detaches scene and visibility entries" {
    var fixture: SceneFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const scene = &fixture.scene;
    const group = try scene.addGroup();
    const survivor = try fixture.add(group);
    for (0..5000) |_| {
        const object = try fixture.add(group);
        try std.testing.expectEqual(@as(u32, 1), object.instance_index.?);
        try scene.removeObject(object);
        try std.testing.expectEqual(@as(usize, 1), scene.game_objects.items.len);
        try std.testing.expectEqual(@as(usize, 1), group.children.items.len);
        try std.testing.expectEqual(@as(usize, 1), scene.space_tree.objects.items.len);
        try std.testing.expect(!scene.instance_buffer.outdated_indices.isSet(1));
    }
    try std.testing.expectEqual(@as(u32, 2), scene.instance_buffer.next_index);
    survivor.setPosition(.{ 4, 5, 6 });
    try std.testing.expect(scene.instance_buffer.outdated_indices.isSet(0));
}

test "group removal follows current hierarchy including moved-in descendants and detached survivors" {
    var fixture: SceneFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const scene = &fixture.scene;
    const car = try scene.addGroup();
    const outside = try scene.addGroup();
    const moved_out = try car.addGroup();
    moved_out.setParent(outside);
    const survivor = try fixture.add(moved_out);
    const detached = try car.addGroup();
    detached.setParent(null);
    _ = try fixture.add(detached);
    const moved_in = try outside.addGroup();
    moved_in.setParent(car);
    const nested = try moved_in.addGroup();
    _ = try fixture.add(nested);
    _ = try fixture.add(car);

    // Even with no allocation available, removal must complete.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    scene.allocator = failing.allocator();
    defer scene.allocator = std.testing.allocator;
    try scene.removeGroup(car);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 3), scene.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), scene.game_objects.items.len);
    try std.testing.expectEqual(@as(usize, 2), scene.space_tree.objects.items.len);
    try std.testing.expectEqual(outside, moved_out.parent.?);
    outside.setPosition(.{ 10, 0, 0 });
    try expectPosition(.{ 11, 2, 3 }, survivor.aggregated_matrix);
    try scene.removeGroup(outside);
    try std.testing.expectEqual(@as(usize, 1), scene.groups.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.game_objects.items.len);
    try std.testing.expect(detached.parent == null);
    try scene.removeGroup(detached);
    try std.testing.expectEqual(@as(usize, 0), scene.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), scene.space_tree.objects.items.len);
}

test "scene mutations reject foreign membership and drawing without changing live objects" {
    var first: SceneFixture = undefined;
    try first.init();
    defer first.deinit();
    var second: SceneFixture = undefined;
    try second.init();
    defer second.deinit();
    const group = try first.scene.addGroup();
    const object = try first.add(group);
    try std.testing.expectError(error.ObjectNotInScene, second.scene.removeObject(object));
    try std.testing.expectError(error.GroupNotInScene, second.scene.removeGroup(group));
    const foreign = try second.add(null);
    try std.testing.expectError(error.GroupBelongsToAnotherScene, group.addObject(foreign));
    first.scene.is_drawing = true;
    defer first.scene.is_drawing = false;
    try std.testing.expectError(error.SceneMutationDuringDraw, first.scene.addGroup());
    try std.testing.expectError(error.SceneMutationDuringDraw, group.addGroup());
    try std.testing.expectError(error.SceneMutationDuringDraw, first.scene.removeObject(object));
    try std.testing.expectError(error.SceneMutationDuringDraw, first.scene.removeGroup(group));
    try std.testing.expectError(error.SceneMutationDuringDraw, first.scene.addPrimitiveObject(.{ .model = &first.model, .position = .{ 0, 0, 0 } }));
    try std.testing.expectEqual(@as(usize, 1), first.scene.game_objects.items.len);
    try std.testing.expectEqual(@as(usize, 1), first.scene.groups.items.len);
}

test "capacity exhaustion preserves existing objects and freed slots remain usable" {
    var fixture: SceneFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var objects: [8]*GameObject = undefined;
    for (&objects) |*object| object.* = try fixture.add(null);
    try std.testing.expectError(error.SceneCapacityReached, fixture.add(null));
    try std.testing.expectEqual(@as(usize, 8), fixture.scene.game_objects.items.len);
    try fixture.scene.removeObject(objects[3]);
    const replacement = try fixture.add(null);
    try std.testing.expectEqual(@as(u32, 3), replacement.instance_index.?);
    try std.testing.expectEqual(@as(usize, 8), fixture.scene.space_tree.objects.items.len);
}
