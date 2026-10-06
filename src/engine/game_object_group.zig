const std = @import("std");
const zmath = @import("zmath");

const world_math = @import("world_math.zig");
const GameObject = @import("./game_object.zig").GameObject;

pub const GroupChild = union(enum) {
    game_object: *GameObject,
    group: *GameObjectGroup,
};

pub const GameObjectGroup = struct {
    allocator: std.mem.Allocator,
    position: world_math.Position,
    rotation: zmath.Quat = zmath.quatFromRollPitchYaw(0, 0, 0),
    // // TODO: Maybe it makes sense to store scale for each axis?
    scale: f32 = 1,
    // TODO: Maybe also keep node transform matrix separately from aggregated?
    aggregated_matrix: world_math.Mat = world_math.identity(),
    // bounding_radius: f32,
    parent: ?*GameObjectGroup,
    children: std.ArrayList(GroupChild) = .empty,
    // Allocation ownership stays with the creator when transforms are reparented.
    owned_groups: std.ArrayList(*GameObjectGroup) = .empty,
    _gc: ?*GameObjectGroup,

    pub fn init(allocator: std.mem.Allocator) !*GameObjectGroup {
        const game_object_group = try allocator.create(GameObjectGroup);
        errdefer allocator.destroy(game_object_group);

        game_object_group.* = GameObjectGroup{
            .allocator = allocator,
            .position = .{ 0, 0, 0 },
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
        game_object_group.owned_groups.deinit(game_object_group.allocator);

        if (game_object_group._gc) |pointer| {
            game_object_group.allocator.destroy(pointer);
        }
    }

    pub fn deinit_recursively(game_object_group: *GameObjectGroup) void {
        for (game_object_group.owned_groups.items) |group| group.deinit_recursively();
        game_object_group.deinit();
    }

    pub fn addGroup(group: *GameObjectGroup) !*GameObjectGroup {
        const new_group = try GameObjectGroup.init(group.allocator);
        errdefer new_group.deinit();
        try group.owned_groups.append(group.allocator, new_group);
        errdefer _ = group.owned_groups.pop();
        try group.attachChild(.{ .group = new_group });
        new_group.parent = group;
        new_group.updateAggregatedMatrix();
        return new_group;
    }

    pub fn addObject(group: *GameObjectGroup, game_object: *GameObject) !void {
        try group.attachChild(.{ .game_object = game_object });
        game_object.setParent(group);
    }

    pub fn attachChild(group: *GameObjectGroup, child: GroupChild) !void {
        for (group.children.items) |existing| {
            if (std.meta.eql(existing, child)) return;
        }
        try group.children.append(group.allocator, child);
    }

    pub fn detachChild(group: *GameObjectGroup, child: GroupChild) void {
        for (group.children.items, 0..) |existing, index| {
            if (std.meta.eql(existing, child)) {
                _ = group.children.swapRemove(index);
                return;
            }
        }
    }

    pub fn setSRT(
        group: *GameObjectGroup,
        position: world_math.Position,
        rotation: zmath.Quat,
        scale: f32,
        parent: ?*GameObjectGroup,
    ) void {
        group.position = position;
        group.rotation = rotation;
        group.scale = scale;
        group.setParent(parent);
    }

    pub fn setScale(group: *GameObjectGroup, scale: f32) void {
        group.scale = scale;
        group.updateAggregatedMatrix();
    }

    pub fn setRotation(group: *GameObjectGroup, rotation: zmath.Quat) void {
        group.rotation = rotation;
        group.updateAggregatedMatrix();
    }

    pub fn setPosition(group: *GameObjectGroup, position: world_math.Position) void {
        group.position = position;
        group.updateAggregatedMatrix();
    }

    pub fn setParent(group: *GameObjectGroup, parent: ?*GameObjectGroup) void {
        if (group.parent != parent) {
            var ancestor = parent;
            while (ancestor) |node| : (ancestor = node.parent) std.debug.assert(node != group);
            if (parent) |new_parent| new_parent.attachChild(.{ .group = group }) catch @panic("Failed to attach group");
            if (group.parent) |old_parent| old_parent.detachChild(.{ .group = group });
            group.parent = parent;
        }
        group.updateAggregatedMatrix();
    }

    fn updateAggregatedMatrix(group: *GameObjectGroup) void {
        group.aggregated_matrix = world_math.fromSRT(group.position, group.rotation, group.scale);

        // if group has parent, multiply its aggregated matrix by parent's
        // aggregated matrix on each update
        if (group.parent) |parent| {
            group.aggregated_matrix = world_math.matMul(
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
