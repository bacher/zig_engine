const std = @import("std");
const zmath = @import("zmath");

const GameObject = @import("./game_object.zig").GameObject;

pub const GroupChild = union(enum) {
    game_object: *const GameObject,
    group: *GameObjectGroup,
};

pub const GameObjectGroup = struct {
    allocator: std.mem.Allocator,
    position: [3]f32,
    rotation: zmath.Quat = zmath.quatFromRollPitchYaw(0, 0, 0),
    scale: f32 = 1,
    aggregated_mat: zmath.Mat = zmath.identity(),
    // bounding_radius: f32,
    children: std.ArrayList(GroupChild) = .empty,
    _gc: ?*GameObjectGroup,

    pub fn init(allocator: std.mem.Allocator) !*GameObjectGroup {
        const game_object_group = try allocator.create(GameObjectGroup);
        errdefer allocator.destroy(game_object_group);

        game_object_group.* = GameObjectGroup{
            .allocator = allocator,
            .position = .{ 0, 0, 0 },
            .rotation = zmath.quatFromRollPitchYaw(0, 0, 0),
            .scale = 1,
            .children = .empty,
            ._gc = game_object_group,
        };

        return game_object_group;
    }

    pub fn deinit(game_object_group: *GameObjectGroup) void {
        game_object_group.children.deinit(game_object_group.allocator);

        if (game_object_group._gc) |pointer| {
            game_object_group.allocator.destroy(pointer);
        }
    }

    pub fn deinit_recursively(game_object_group: *GameObjectGroup) void {
        for (game_object_group.children.items) |child| {
            switch (child) {
                .group => |group| {
                    group.deinit_recursively();
                },
                else => {},
            }
        }
        game_object_group.deinit();
    }

    pub fn addGroup(group: *GameObjectGroup) !*GameObjectGroup {
        const new_group = try GameObjectGroup.init(group.allocator);

        const child = try group.children.addOne(group.allocator);
        child.* = .{
            .group = new_group,
        };

        return new_group;
    }

    pub fn addObject(group: *GameObjectGroup, game_object: *GameObject) !void {
        const added = try group.children.addOne(group.allocator);
        added.* = .{
            .game_object = game_object,
        };
        game_object.aggregated_matrix = group.aggregated_mat;
    }
};
