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
    const tree = try SpaceTree(GameObject).init(allocator);
    defer tree.deinit();
    const root = try GameObjectGroup.init(allocator);
    defer root.deinit_recursively();
    const child = try root.addGroup();
    root.setPosition(.{ 1e9, -1e9, 1e9 });
    child.setPosition(.{ 0.125, 0.25, 0.5 });
    var scene: Scene = undefined;
    scene.space_tree = tree;
    scene.instance_buffer.outdated_indices = try std.DynamicBitSetUnmanaged.initEmpty(allocator, 1);
    defer scene.instance_buffer.outdated_indices.deinit(allocator);
    var model: PrimitiveModel = undefined; // No geometry or GPU is needed for transforms.
    const object = try GameObject.init(allocator, .{
        .scene = &scene,
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
    const group = try GameObjectGroup.init(allocator);
    defer group.deinit_recursively();
    var scene: Scene = undefined;
    var terrain: @import("model.zig").TerrainHeightMapModel = undefined;
    const first = try GameObject.init(allocator, .{
        .scene = &scene,
        .model = .{ .terrain_height_map_model = &terrain },
        .position = .{ 0, 0, 0 },
        .parent = group,
        .instance_index = null,
        .skip_space_tree = true,
    });
    const second = try GameObject.init(allocator, .{
        .scene = &scene,
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
