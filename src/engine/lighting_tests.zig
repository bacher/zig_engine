const std = @import("std");
const Scene = @import("scene.zig").Scene;
const DirectionalLightParams = @import("light.zig").DirectionalLightParams;

test "scene owns one directional light and rejects a second without changing its cascades" {
    // Light setup needs no allocator or GPU state.
    var scene: Scene = undefined;
    scene.directional_light = null;
    const params: DirectionalLightParams = .{
        .direction = .{ 0.5, 0.5, -1, 0 },
        .color = .{ 1, 1, 1, 1 },
        .intensity = 1,
    };
    try scene.addDirectionalLight(params);
    try std.testing.expectEqualDeep(params, scene.directional_light.?.params);
    scene.directional_light.?.cascades[0].chunk = .{ 2, 3, 4 };

    try std.testing.expectError(error.DirectionalLightAlreadyExists, scene.addDirectionalLight(.{
        .direction = .{ -0.5, 0.5, -1, 0 },
        .color = .{ 1, 0, 0, 1 },
        .intensity = 2,
    }));
    try std.testing.expectEqualDeep(params, scene.directional_light.?.params);
    try std.testing.expectEqual(@as(@Vector(3, i32), .{ 2, 3, 4 }), scene.directional_light.?.cascades[0].chunk);
}
