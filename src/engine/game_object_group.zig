const std = @import("std");
const zmath = @import("zmath");

const utils = @import("./utils.zig");
const GameObject = @import("./game_object.zig").GameObject;

pub const GroupChild = union(enum) {
    game_object: *GameObject,
    group: *GameObjectGroup,
};

pub const GameObjectGroup = struct {
    allocator: std.mem.Allocator,
    position: zmath.Vec,
    rotation: zmath.Quat = zmath.quatFromRollPitchYaw(0, 0, 0),
    // // TODO: Maybe it makes sense to store scale for each axis?
    scale: f32 = 1,
    // TODO: Maybe also keep node transform matrix separately from aggregated?
    aggregated_matrix: zmath.Mat = zmath.identity(),
    // bounding_radius: f32,
    parent: ?*GameObjectGroup,
    children: std.ArrayList(GroupChild) = .empty,
    _gc: ?*GameObjectGroup,

    pub fn init(allocator: std.mem.Allocator) !*GameObjectGroup {
        const game_object_group = try allocator.create(GameObjectGroup);
        errdefer allocator.destroy(game_object_group);

        game_object_group.* = GameObjectGroup{
            .allocator = allocator,
            .position = .{ 0, 0, 0, 0 },
            .rotation = zmath.quatFromRollPitchYaw(0, 0, 0),
            .scale = 1,
            .parent = null,
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

        game_object.setParent(group);
    }

    pub fn setSRT(
        group: *GameObjectGroup,
        position: zmath.Vec,
        rotation: zmath.Quat,
        scale: f32,
        parent: ?*GameObjectGroup,
    ) void {
        group.position = utils.pos0(position);
        group.rotation = rotation;
        group.scale = scale;
        group.parent = parent;
        group.updateAggregatedMatrix();
    }

    pub fn setScale(group: *GameObjectGroup, scale: f32) void {
        group.scale = scale;
        group.updateAggregatedMatrix();
    }

    pub fn setRotation(group: *GameObjectGroup, rotation: zmath.Quat) void {
        group.rotation = rotation;
        group.updateAggregatedMatrix();
    }

    pub fn setPosition(group: *GameObjectGroup, position: zmath.Vec) void {
        group.position = utils.pos0(position);
        group.updateAggregatedMatrix();
    }

    pub fn setParent(group: *GameObjectGroup, parent: ?*GameObjectGroup) void {
        group.parent = parent;
        group.updateAggregatedMatrix();
    }

    fn updateAggregatedMatrix(group: *GameObjectGroup) void {
        utils.updateAggregatedMatrix_abstract(GameObjectGroup, group);

        // if group has parent, multiply its aggregated matrix by parent's
        // aggregated matrix on each update
        if (group.parent) |parent| {
            group.aggregated_matrix = utils.matMul(
                parent.aggregated_matrix,
                group.aggregated_matrix,
            );
        }

        for (group.children.items) |child| {
            switch (child) {
                .group => |child_group| {
                    child_group.updateAggregatedMatrix();
                },
                .game_object => |game_object| {
                    game_object.onParentUpdated();
                },
            }
        }
    }
};
