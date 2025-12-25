const std = @import("std");
const math = std.math;

const BoundBox = @import("./bound_box.zig").BoundBox;

const DEBUG = false;
const STRICT = true;

const LEVELS_COUNT = 3;
const MAX_LEVEL = LEVELS_COUNT - 1;
const GRID_DIMENSTION = 16;
const GRID_OFFSET: u8 = @divExact(GRID_DIMENSTION, 2);
const CHILD_NODE_COUNT = 8;

// const GRID_NODE_SIZE: f32 = 16;
const GRID_NODE_SIZE: f32 = 32;
// const GRID_NODE_SIZE: f32 = 64;
const GRID_NODE_SIZE_INV: f32 = 1 / GRID_NODE_SIZE;
const ZERO_Z = GRID_NODE_SIZE * 0.25;

const sizes = sizes: {
    var arr: [LEVELS_COUNT]f32 = undefined;
    for (0..LEVELS_COUNT) |index| {
        arr[index] = GRID_NODE_SIZE / std.math.pow(f32, 2, index);
    }
    break :sizes arr;
};

const radiuses = radiuses: {
    var arr: [LEVELS_COUNT]f32 = undefined;
    for (sizes, 0..) |size, index| {
        arr[index] = size * 0.5 * math.sqrt2;
    }
    break :radiuses arr;
};

// Node [GRID_OFFSET, GRID_OFFSET] starts at (0, 0) and goes until (GRID_NODE_SIZE, GRID_NODE_SIZE).

const Debug = struct {
    var find_invocations_count: u32 = 0;
    var active_space_nodes_count: u32 = 0;
};

pub fn SpaceTree(comptime ElementType: type) type {
    return struct {
        const This = @This();
        const ThisSpaceNode = SpaceNode(ElementType);
        const ObjectsHashMap = std.AutoArrayHashMap(*const ElementType, bool);

        allocator: std.mem.Allocator,
        grid: [GRID_DIMENSTION][GRID_DIMENSTION]*ThisSpaceNode,
        objects: ObjectsHashMap,

        pub fn init(allocator: std.mem.Allocator) !*This {
            const space_tree_ptr = try allocator.create(This);
            space_tree_ptr.* = .{
                .allocator = allocator,
                .grid = undefined,
                .objects = ObjectsHashMap.init(allocator),
            };
            errdefer space_tree_ptr.objects.deinit();
            try space_tree_ptr.objects.ensureTotalCapacity(1024);

            for (0..GRID_DIMENSTION) |index_y| {
                const cell_y: i8 = @as(i8, @intCast(index_y)) - GRID_OFFSET;

                for (0..GRID_DIMENSTION) |index_x| {
                    const cell_x: i8 = @as(i8, @intCast(index_x)) - GRID_OFFSET;

                    const center: [3]f32 = .{
                        (@as(f32, @floatFromInt(cell_x)) + 0.5) * GRID_NODE_SIZE,
                        (@as(f32, @floatFromInt(cell_y)) + 0.5) * GRID_NODE_SIZE,
                        ZERO_Z,
                    };

                    std.debug.print("grid node [x={d:2}, y={d:2}] center: {d:8.1},{d:8.1},{d:8.1}\n", .{
                        cell_x,
                        cell_y,
                        center[0],
                        center[1],
                        center[2],
                    });

                    const node = try allocator.create(ThisSpaceNode);
                    node.* = ThisSpaceNode.init(0, center);
                    errdefer allocator.destroy(node);

                    space_tree_ptr.grid[index_y][index_x] = node;

                    try space_tree_ptr.createChildNodes(node);
                }
            }

            return space_tree_ptr;
        }

        pub fn deinit(space_tree: *This) void {
            space_tree.objects.deinit();

            for (0..GRID_DIMENSTION) |index_y| {
                for (0..GRID_DIMENSTION) |index_x| {
                    const child_node = space_tree.grid[index_y][index_x];
                    space_tree.destroyLevel(child_node);

                    child_node.deinit(space_tree.allocator);
                    space_tree.allocator.destroy(child_node);
                }
            }

            space_tree.allocator.destroy(space_tree);
        }

        pub fn addObject(space_tree: *const This, object: *const ElementType) !void {
            if (DEBUG) {
                std.debug.print("add object at the root level, center=({d},{d},{d}) r={d}\n", .{
                    object.position[0],
                    object.position[1],
                    object.position[2],
                    object.bounding_radius,
                });
            }

            const bound_box: BoundBox(f32) = .{
                .x = .{
                    .start = object.position[0] - object.bounding_radius,
                    .end = object.position[0] + object.bounding_radius,
                },
                .y = .{
                    .start = object.position[1] - object.bounding_radius,
                    .end = object.position[1] + object.bounding_radius,
                },
                .z = .{
                    .start = object.position[2] - object.bounding_radius,
                    .end = object.position[2] + object.bounding_radius,
                },
            };

            if (DEBUG) {
                std.debug.print("bounding box, x=({d} {d})\n", .{ bound_box.x.start, bound_box.x.end });
                std.debug.print("              y=({d} {d})\n", .{ bound_box.y.start, bound_box.y.end });
                std.debug.print("              z=({d} {d})\n", .{ bound_box.z.start, bound_box.z.end });
            }

            const x0 = @as(i32, @intFromFloat(@floor(bound_box.x.start * GRID_NODE_SIZE_INV))) + GRID_OFFSET;
            const x1 = @as(i32, @intFromFloat(@ceil(bound_box.x.end * GRID_NODE_SIZE_INV))) + GRID_OFFSET;

            const y0 = @as(i32, @intFromFloat(@floor(bound_box.y.start * GRID_NODE_SIZE_INV))) + GRID_OFFSET;
            const y1 = @as(i32, @intFromFloat(@ceil(bound_box.y.end * GRID_NODE_SIZE_INV))) + GRID_OFFSET;

            if (DEBUG) {
                if (x0 == x1 and y0 == y1) {
                    std.debug.print("node: {},{}\n", .{ x0, y0 });
                } else {
                    std.debug.print("nodes: {},{} to {},{}\n", .{ x0, y0, x1, y1 });
                }
            }

            if (STRICT) {
                if (x0 >= GRID_DIMENSTION or x1 >= GRID_DIMENSTION or y0 >= GRID_DIMENSTION or y1 >= GRID_DIMENSTION or x0 < 0 or x1 < 0 or y0 < 0 or y1 < 0) {
                    std.debug.print("[STRICT] object bound box is partially out of the grid bounds, center=({d},{d},{d}) r={d}\n", .{
                        object.position[0],
                        object.position[1],
                        object.position[2],
                        object.bounding_radius,
                    });
                    std.debug.print("[STRICT]   nodes: {},{} to {},{}\n", .{ x0, y0, x1, y1 });
                }
            }

            for (@intCast(@max(0, x0))..@intCast(@min(GRID_DIMENSTION, x1))) |x| {
                for (@intCast(@max(0, y0))..@intCast(@min(GRID_DIMENSTION, y1))) |y| {
                    _ = try space_tree.grid[y][x].addObject(space_tree.allocator, object, bound_box);
                }
            }
        }

        pub fn getObjectsInBoundBox(space_tree: *This, bound_box: BoundBox(f32)) []*const ElementType {
            Debug.find_invocations_count = 0;
            Debug.active_space_nodes_count = 0;

            const x0 = @as(i32, @intFromFloat(bound_box.x.start * GRID_NODE_SIZE_INV));
            const x1 = @as(i32, @intFromFloat(bound_box.x.end * GRID_NODE_SIZE_INV));
            const y0 = @as(i32, @intFromFloat(bound_box.y.start * GRID_NODE_SIZE_INV));
            const y1 = @as(i32, @intFromFloat(bound_box.y.end * GRID_NODE_SIZE_INV));

            const index_x0: u8 = @intCast(@max(0, x0 + GRID_OFFSET));
            const index_x1: u8 = @intCast(@min(GRID_DIMENSTION, x1 + GRID_OFFSET + 1));
            const index_y0: u8 = @intCast(@max(0, y0 + GRID_OFFSET));
            const index_y1: u8 = @intCast(@min(GRID_DIMENSTION, y1 + GRID_OFFSET + 1));

            space_tree.objects.clearRetainingCapacity();

            var grid_nodes_count: u32 = 0;
            for (index_y0..index_y1) |index_y| {
                for (index_x0..index_x1) |index_x| {
                    space_tree.grid[index_y][index_x].findObjectsInBoundBox(space_tree.allocator, bound_box, &space_tree.objects) catch |err| {
                        std.debug.panic("findObjectsInBoundBox failed with error: {!}", .{err});
                    };
                    grid_nodes_count += 1;
                }
            }

            Debug.active_space_nodes_count = grid_nodes_count;

            return space_tree.objects.keys();
        }

        pub fn getLastGetObjectsInBoundBoxStats(_: *const This) struct { invocations_count: u32, active_space_nodes_count: u32 } {
            return .{
                .invocations_count = Debug.find_invocations_count,
                .active_space_nodes_count = Debug.active_space_nodes_count,
            };
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
        intersecting_objects: std.AutoArrayHashMapUnmanaged(*const ElementType, bool),
        nested_objects_count: u32,

        fn init(level: u8, center: [3]f32) ThisSpaceNode {
            return .{
                .level = level,
                .center = center,
                .child_nodes = undefined,
                .contained_objects = .empty,
                .intersecting_objects = .empty,
                .nested_objects_count = 0,
            };
        }

        fn deinit(space_node: *ThisSpaceNode, allocator: std.mem.Allocator) void {
            space_node.contained_objects.deinit(allocator);
            space_node.intersecting_objects.deinit(allocator);
        }

        fn addObject(
            space_node: *ThisSpaceNode,
            allocator: std.mem.Allocator,
            object: *const ElementType,
            bound_box: BoundBox(f32),
        ) !bool { // returns true if object was added to the node

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
            if (len >= radiuses[space_node.level] + object.bounding_radius) {
                // std.debug.print("len={d} Rc={d} Ro={d}\n", .{ len, radiuses[space_node.level], object.bounding_radius });
                // std.debug.print("spheres are not intersecing, skip\n", .{});
                return false;
            }

            // if cell sphere is fully inside of object sphere
            if (len + radiuses[space_node.level] <= object.bounding_radius) {
                try space_node.contained_objects.put(allocator, object, true);
                // std.debug.print("full contained, skipping subdivision\n", .{});
                return true;
            }

            // on max level we add object to intersecting objects instead of subdividing
            if (space_node.level == MAX_LEVEL) {
                try space_node.intersecting_objects.put(allocator, object, true);
                return true;
            } else {
                const sub_boxes = space_node.getSubBoxesByBoundBox(bound_box);
                const sub_boxes_indexes = space_node.getChildNodeIndexesBySubBoxes(sub_boxes);

                var something_was_added = false;
                for (sub_boxes_indexes) |index| {
                    if (index == 255) {
                        break;
                    }
                    const was_added = try space_node.child_nodes[index].addObject(allocator, object, bound_box);

                    if (was_added) {
                        something_was_added = true;
                        space_node.nested_objects_count += 1;
                    }
                }
                return something_was_added;
            }
        }

        fn findObjectsInBoundBox(
            space_node: *const ThisSpaceNode,
            allocator: std.mem.Allocator,
            bound_box: BoundBox(f32),
            objects: *std.AutoArrayHashMap(*const ElementType, bool),
        ) !void {
            Debug.find_invocations_count += 1;

            for (space_node.contained_objects.keys()) |object| {
                try objects.put(object, true);
            }

            if (space_node.level == MAX_LEVEL) {
                // TODO: Is it correct to assume that intersecting objects should be taken only from the max level?
                for (space_node.intersecting_objects.keys()) |object| {
                    try objects.put(object, true);
                }

                // the level does not have any children, so we can return early
                return;
            }

            // descend into the children only if node has nested objects
            if (space_node.nested_objects_count > 0) {
                const sub_boxes = space_node.getSubBoxesByBoundBox(bound_box);
                const sub_boxes_indexes = space_node.getChildNodeIndexesBySubBoxes(sub_boxes);

                for (sub_boxes_indexes) |index| {
                    if (index == 255) {
                        break;
                    }
                    try space_node.child_nodes[index].findObjectsInBoundBox(allocator, bound_box, objects);
                }
            }
        }

        fn getSubBoxesByBoundBox(space_node: *const ThisSpaceNode, bound_box: BoundBox(f32)) BoundBox(u8) {
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

            return sub_box;
        }

        fn getChildNodeIndexesBySubBoxes(
            _: *const ThisSpaceNode,
            sub_box: BoundBox(u8),
        ) [8]u8 {
            var list: [8]u8 = undefined;
            // var list = std.ArrayList(u8).init(allocator);
            // errdefer list.deinit();

            var i: u8 = 0;
            for (sub_box.z.start..sub_box.z.end) |z_index| {
                for (sub_box.y.start..sub_box.y.end) |y_index| {
                    for (sub_box.x.start..sub_box.x.end) |x_index| {
                        const cell_index = @as(u8, @intCast(z_index * 4 + y_index * 2 + x_index));
                        // try list.append(cell_index);
                        list[i] = cell_index;
                        i += 1;
                    }
                }
            }
            if (i != 8) {
                list[i] = 255;
            }

            return list;
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
    bounding_radius: f32,
};

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
    //     .bounding_radius = 0.8,
    // };
    //
    // try space_tree.addObject(&obj_1);

    std.debug.print("\n=== obj_2 ===\n", .{});

    const obj_2: TestObject = .{
        .id = 43,
        .position = .{ 8, 3.4, 3.2 },
        .bounding_radius = 5,
    };

    try space_tree.addObject(&obj_2);
}
