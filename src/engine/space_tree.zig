const std = @import("std");

const MAX_LEVEL = 4;
const GRID_DIMENSTION = 4;
const CHILD_NODE_COUNT = 8;

// Levels (n = meters):
// 0 = 16
// 1 = 8
// 2 = 4
// 3 = 2
// 4 = 1

const sizes = [MAX_LEVEL + 1]f32{ 8, 4, 2, 1, 0.5 };
const ZERO_Z = sizes[0] * 0.25;

pub fn SpaceTree(comptime ElementType: type) type {
    return struct {
        const This = @This();
        const ThisSpaceNode = SpaceNode(ElementType);

        allocator: std.mem.Allocator,
        grid: [GRID_DIMENSTION][GRID_DIMENSTION]*ThisSpaceNode,

        pub fn init(allocator: std.mem.Allocator) !*This {
            const step = sizes[0];

            const space_tree_ptr = try allocator.create(This);
            space_tree_ptr.* = .{
                .allocator = allocator,
                .grid = undefined,
            };

            for (0..GRID_DIMENSTION) |index_y| {
                const cell_y: i8 = @as(i8, @intCast(index_y)) - @as(i8, @divExact(GRID_DIMENSTION, 2));

                for (0..GRID_DIMENSTION) |index_x| {
                    const cell_x: i8 = @as(i8, @intCast(index_x)) - @as(i8, @divExact(GRID_DIMENSTION, 2));

                    const center: [3]f32 = .{
                        (@as(f32, @floatFromInt(cell_x)) + 0.5) * step,
                        (@as(f32, @floatFromInt(cell_y)) + 0.5) * step,
                        ZERO_Z,
                    };

                    const node = try allocator.create(ThisSpaceNode);
                    node.* = ThisSpaceNode.init(allocator, 0, center);
                    errdefer allocator.destroy(node);

                    space_tree_ptr.grid[index_x][index_y] = node;

                    try space_tree_ptr.createChildNodes(node);
                }
            }

            return space_tree_ptr;
        }

        pub fn deinit(space_tree: *const This) void {
            for (0..GRID_DIMENSTION) |index_y| {
                for (0..GRID_DIMENSTION) |index_x| {
                    const child_node = space_tree.grid[index_x][index_y];
                    space_tree.destroyLevel(child_node);
                    space_tree.allocator.destroy(child_node);
                }
            }

            space_tree.allocator.destroy(space_tree);
        }

        fn createChildNodes(space_tree: *const This, node: *ThisSpaceNode) !void {
            const allocator = space_tree.allocator;
            const c = node.center;

            for (0..CHILD_NODE_COUNT) |index| {
                const child_node = try space_tree.allocator.create(ThisSpaceNode);
                const step = sizes[node.level] * 0.5;

                const center: [3]f32 = center: {
                    switch (index) {
                        0 => {
                            break :center .{ c[0] - step, c[1] - step, c[2] - step };
                        },
                        1 => {
                            break :center .{ c[0] + step, c[1] - step, c[2] - step };
                        },
                        2 => {
                            break :center .{ c[0] - step, c[1] + step, c[2] - step };
                        },
                        3 => {
                            break :center .{ c[0] + step, c[1] + step, c[2] - step };
                        },
                        4 => {
                            break :center .{ c[0] - step, c[1] - step, c[2] + step };
                        },
                        5 => {
                            break :center .{ c[0] + step, c[1] - step, c[2] + step };
                        },
                        6 => {
                            break :center .{ c[0] - step, c[1] + step, c[2] + step };
                        },
                        7 => {
                            break :center .{ c[0] + step, c[1] + step, c[2] + step };
                        },
                        else => {
                            unreachable;
                        },
                    }
                };

                child_node.* = ThisSpaceNode.init(allocator, node.level + 1, center);
                node.child_nodes[index] = child_node;

                if (child_node.level < MAX_LEVEL) {
                    try space_tree.createChildNodes(child_node);
                }
            }
        }

        fn destroyLevel(space_tree: *const This, node: *ThisSpaceNode) void {
            for (0..CHILD_NODE_COUNT) |index| {
                const child_node = node.child_nodes[index];
                if (child_node.level < MAX_LEVEL) {
                    space_tree.destroyLevel(child_node);
                }

                child_node.deinit();
                space_tree.allocator.destroy(child_node);
            }
        }
    };
}

pub fn SpaceNode(comptime ElementType: type) type {
    return struct {
        const ThisSpaceNode = @This();

        level: u8,
        center: [3]f32,
        child_nodes: [CHILD_NODE_COUNT]*ThisSpaceNode,
        contained_objects: std.AutoArrayHashMap(*ElementType, bool),
        partially_contained_objects: std.AutoArrayHashMap(*ElementType, bool),

        fn init(allocator: std.mem.Allocator, level: u8, center: [3]f32) ThisSpaceNode {
            return .{
                .level = level,
                .center = center,
                .child_nodes = undefined,
                .contained_objects = .init(allocator),
                .partially_contained_objects = .init(allocator),
            };
        }

        fn deinit(space_node: *ThisSpaceNode) void {
            space_node.contained_objects.deinit();
            space_node.partially_contained_objects.deinit();
        }
    };
}

const TestObject = struct {
    id: u64,
};

test "init" {
    const allocator = std.testing.allocator;

    const space_tree = try SpaceTree(TestObject).init(allocator);
    defer space_tree.deinit();

    try std.testing.expectEqual(space_tree.grid[0][0].level, 0);

    printNodeInfo(space_tree.grid[0][0]);
    printNodeInfo(space_tree.grid[GRID_DIMENSTION - 1][GRID_DIMENSTION - 1]);
}

fn printNodeInfo(node: *SpaceNode(TestObject)) void {
    std.debug.print("center: ({d},{d},{d})\n", .{ node.center[0], node.center[1], node.center[2] });
}
