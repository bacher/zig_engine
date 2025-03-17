const std = @import("std");
const math = std.math;

const MAX_LEVEL = 4;
const GRID_DIMENSTION = 4;
const GRID_OFFSET: u8 = @divExact(GRID_DIMENSTION, 2);
const CHILD_NODE_COUNT = 8;

const sizes = [MAX_LEVEL + 1]f32{ 16, 8, 4, 2, 1 };
const radiuses = radiuses: {
    var arr: [MAX_LEVEL + 1]f32 = undefined;
    for (sizes, 0..) |size, index| {
        arr[index] = size * 0.5 * math.sqrt2;
    }
    break :radiuses arr;
};
const GRID_NODE_SIZE = sizes[0];
const GRID_NODE_SIZE_INV: f32 = 1 / GRID_NODE_SIZE;
const ZERO_Z = GRID_NODE_SIZE * 0.25;

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
                const cell_y: i8 = @as(i8, @intCast(index_y)) - GRID_OFFSET;

                for (0..GRID_DIMENSTION) |index_x| {
                    const cell_x: i8 = @as(i8, @intCast(index_x)) - GRID_OFFSET;

                    const center: [3]f32 = .{
                        (@as(f32, @floatFromInt(cell_x)) + 0.5) * step,
                        (@as(f32, @floatFromInt(cell_y)) + 0.5) * step,
                        ZERO_Z,
                    };

                    const node = try allocator.create(ThisSpaceNode);
                    node.* = ThisSpaceNode.init(0, center);
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

        pub fn addObject(space_tree: *const This, object: *const ElementType) !void {
            std.debug.print("add object at the root level, center=({d},{d},{d}) r={d}\n", .{
                object.position[0],
                object.position[1],
                object.position[2],
                object.radius,
            });

            const bound_box: BoundBox(f32) = .{
                .x = .{
                    .start = object.position[0] - object.radius,
                    .end = object.position[0] + object.radius,
                },
                .y = .{
                    .start = object.position[1] - object.radius,
                    .end = object.position[1] + object.radius,
                },
                .z = .{
                    .start = object.position[2] - object.radius,
                    .end = object.position[2] + object.radius,
                },
            };

            std.debug.print("bounding box, x=({d} {d})\n", .{ bound_box.x.start, bound_box.x.end });
            std.debug.print("              y=({d} {d})\n", .{ bound_box.y.start, bound_box.y.end });
            std.debug.print("              z=({d} {d})\n", .{ bound_box.z.start, bound_box.z.end });

            const x0: u8 = @intCast(@as(i8, @intFromFloat(@floor(bound_box.x.start * GRID_NODE_SIZE_INV))) + GRID_OFFSET);
            const x1: u8 = @intCast(@as(i8, @intFromFloat(@ceil(bound_box.x.end * GRID_NODE_SIZE_INV))) + GRID_OFFSET);

            const y0: u8 = @intCast(@as(i8, @intFromFloat(@floor(bound_box.y.start * GRID_NODE_SIZE_INV))) + GRID_OFFSET);
            const y1: u8 = @intCast(@as(i8, @intFromFloat(@ceil(bound_box.y.end * GRID_NODE_SIZE_INV))) + GRID_OFFSET);

            for (x0..x1) |x| {
                for (y0..y1) |y| {
                    std.debug.print("sub nodes: {} {}\n", .{ x, y });
                    try space_tree.grid[x][y].addObject(space_tree.allocator, object, bound_box);
                }
            }
        }

        fn createChildNodes(space_tree: *const This, node: *ThisSpaceNode) !void {
            const c = node.center;

            for (0..CHILD_NODE_COUNT) |index| {
                const child_node = try space_tree.allocator.create(ThisSpaceNode);
                const step = sizes[node.level] * 0.25;

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

                child_node.* = ThisSpaceNode.init(node.level + 1, center);
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

                child_node.deinit(space_tree.allocator);
                space_tree.allocator.destroy(child_node);
            }
        }
    };
}

fn SpaceNode(comptime ElementType: type) type {
    return struct {
        const ThisSpaceNode = @This();

        level: u8,
        center: [3]f32,
        child_nodes: [CHILD_NODE_COUNT]*ThisSpaceNode,
        contained_objects: std.AutoArrayHashMapUnmanaged(*const ElementType, bool),
        partially_contained_objects: std.AutoArrayHashMapUnmanaged(*const ElementType, bool),

        fn init(level: u8, center: [3]f32) ThisSpaceNode {
            return .{
                .level = level,
                .center = center,
                .child_nodes = undefined,
                .contained_objects = .empty,
                .partially_contained_objects = .empty,
            };
        }

        fn deinit(space_node: *ThisSpaceNode, allocator: std.mem.Allocator) void {
            space_node.contained_objects.deinit(allocator);
            space_node.partially_contained_objects.deinit(allocator);
        }

        fn addObject(
            space_node: *ThisSpaceNode,
            allocator: std.mem.Allocator,
            object: *const ElementType,
            bound_box: BoundBox(f32),
        ) !void {
            // std.debug.print("addObject to level={}\n", .{space_node.level});
            // space_node.printCenter();

            const delta = .{
                space_node.center[0] - object.position[0],
                space_node.center[1] - object.position[1],
                space_node.center[2] - object.position[2],
            };

            // TODO: test replacing sqrt by squaring the second part of the formula
            const len = math.pow(
                f32,
                delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2],
                0.5,
            );

            // if bounding spheres does not intersect then skip object
            if (len >= radiuses[space_node.level] + object.radius) {
                // std.debug.print("len={d} Rc={d} Ro={d}\n", .{ len, radiuses[space_node.level], object.radius });
                // std.debug.print("spheres are not intersecing, skip\n", .{});
                return;
            }

            // if cell sphere is fully inside of object sphere
            if (len + radiuses[space_node.level] <= object.radius) {
                try space_node.contained_objects.put(allocator, object, true);
                // std.debug.print("full contained, skipping subdivision\n", .{});
                return;
            }

            if (space_node.level == MAX_LEVEL) {
                try space_node.partially_contained_objects.put(allocator, object, true);
                // std.debug.print("partially contained\n", .{});
                return;
            }

            var sub_box: BoundBox(u8) = .{
                .x = .init(0, 2),
                .y = .init(0, 2),
                .z = .init(0, 2),
            };

            if (bound_box.x.end <= space_node.center[0]) {
                sub_box.x.end = 1;
            } else if (bound_box.x.start >= space_node.center[0]) {
                sub_box.x.start = 1;
            }
            if (bound_box.y.end <= space_node.center[1]) {
                sub_box.y.end = 1;
            } else if (bound_box.y.start >= space_node.center[1]) {
                sub_box.y.start = 1;
            }
            if (bound_box.z.end <= space_node.center[2]) {
                sub_box.z.end = 1;
            } else if (bound_box.z.start >= space_node.center[2]) {
                sub_box.z.start = 1;
            }

            // std.debug.print("subsecting: x: {d}-{d} y: {d}-{d} z: {d}-{d}\n", .{
            //     sub_box.x.start,
            //     sub_box.x.end,
            //     sub_box.y.start,
            //     sub_box.y.end,
            //     sub_box.z.start,
            //     sub_box.z.end,
            // });

            for (sub_box.z.start..sub_box.z.end) |z_index| {
                for (sub_box.y.start..sub_box.y.end) |y_index| {
                    for (sub_box.x.start..sub_box.x.end) |x_index| {
                        const cell_index = z_index * 4 + y_index * 2 + x_index;
                        try space_node.child_nodes[cell_index].addObject(allocator, object, bound_box);
                    }
                }
            }
        }

        fn printCenter(space_node: *const ThisSpaceNode) void {
            std.debug.print("  center=({d},{d},{d})\n", .{
                space_node.center[0],
                space_node.center[1],
                space_node.center[2],
            });
        }
    };
}

const TestObject = struct {
    id: u64,
    position: [3]f32,
    radius: f32,
};

fn Range(comptime ElementType: type) type {
    return struct {
        const This = @This();

        start: ElementType,
        end: ElementType,

        fn init(start: ElementType, end: ElementType) This {
            return .{ .start = start, .end = end };
        }
    };
}

fn BoundBox(comptime ElementType: type) type {
    return struct {
        x: Range(ElementType),
        y: Range(ElementType),
        z: Range(ElementType),
    };
}

fn printNodeInfo(node: *SpaceNode(TestObject)) void {
    std.debug.print("[node info] level={d} center=({d},{d},{d})\n", .{
        node.level,
        node.center[0],
        node.center[1],
        node.center[2],
    });
}

test "init" {
    const allocator = std.testing.allocator;

    const space_tree = try SpaceTree(TestObject).init(
        allocator,
    );
    defer space_tree.deinit();

    try std.testing.expectEqual(space_tree.grid[0][0].level, 0);

    printNodeInfo(space_tree.grid[0][0]);
    printNodeInfo(space_tree.grid[GRID_DIMENSTION - 1][GRID_DIMENSTION - 1]);
    printNodeInfo(space_tree.grid[GRID_DIMENSTION - 1][GRID_DIMENSTION - 1].child_nodes[0]);
    printNodeInfo(space_tree.grid[GRID_DIMENSTION - 1][GRID_DIMENSTION - 1].child_nodes[7]);

    // std.debug.print("\n=== obj_1 ===\n", .{});
    //
    // const obj_1: TestObject = .{
    //     .id = 42,
    //     .position = .{ 8, 3.4, 3.2 },
    //     .radius = 0.8,
    // };
    //
    // try space_tree.addObject(&obj_1);

    std.debug.print("\n=== obj_2 ===\n", .{});

    const obj_2: TestObject = .{
        .id = 43,
        .position = .{ 8, 3.4, 3.2 },
        .radius = 5,
    };

    try space_tree.addObject(&obj_2);
}
