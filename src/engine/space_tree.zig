const std = @import("std");

const MAX_LEVEL = 4;

// Levels (n = meters):
// 0 = 16
// 1 = 8
// 2 = 4
// 3 = 2
// 4 = 1

pub fn SpaceTree(comptime ElementType: type) type {
    return struct {
        const This = @This();
        const ThisSpaceNode = SpaceNode(ElementType);

        allocator: std.mem.Allocator,
        root_node: *ThisSpaceNode,

        pub fn init(allocator: std.mem.Allocator) !*This {
            const root_node = try allocator.create(ThisSpaceNode);
            root_node.* = ThisSpaceNode.init(allocator, 0);
            errdefer allocator.destroy(root_node);

            const space_tree_ptr = try allocator.create(This);
            space_tree_ptr.* = .{
                .allocator = allocator,
                .root_node = root_node,
            };

            try space_tree_ptr.createLevel(space_tree_ptr.root_node);

            return space_tree_ptr;
        }

        pub fn deinit(space_tree: *const This) void {
            space_tree.destroyLevel(space_tree.root_node);

            space_tree.allocator.destroy(space_tree.root_node);
            space_tree.allocator.destroy(space_tree);
        }

        fn createLevel(space_tree: *const This, node: *ThisSpaceNode) !void {
            const allocator = space_tree.allocator;

            for (0..4) |index| {
                const child_node = try space_tree.allocator.create(ThisSpaceNode);
                child_node.* = .init(allocator, node.level + 1);
                node.child_nodes[index] = child_node;

                if (child_node.level <= MAX_LEVEL) {
                    try space_tree.createLevel(child_node);
                }
            }
        }

        fn destroyLevel(space_tree: *const This, node: *ThisSpaceNode) void {
            for (0..4) |index| {
                const child_node = node.child_nodes[index];
                if (child_node.level <= MAX_LEVEL) {
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
        child_nodes: [4]*ThisSpaceNode,
        contained_objects: std.AutoArrayHashMap(*ElementType, bool),
        partially_contained_objects: std.AutoArrayHashMap(*ElementType, bool),

        fn init(allocator: std.mem.Allocator, level: u8) ThisSpaceNode {
            return .{
                .level = level,
                .center = .{ 0, 0, 0 },
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

test "init" {
    const TestObject = struct {
        id: u64,
    };

    const allocator = std.testing.allocator;

    const space_tree = try SpaceTree(TestObject).init(allocator);
    defer space_tree.deinit();

    try std.testing.expectEqual(space_tree.root_node.level, 0);
}
