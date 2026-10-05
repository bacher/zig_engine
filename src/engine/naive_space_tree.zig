const std = @import("std");
const BoundBox = @import("bound_box.zig").BoundBox;

/// Temporary unbounded visibility index. Every registered object is a candidate
/// for both the camera and shadow passes; no spatial culling is performed.
pub fn SpaceTree(comptime ElementType: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        objects: std.ArrayList(*ElementType) = .empty,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.objects.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn addObject(self: *Self, object: *ElementType) !void {
            if (std.mem.indexOfScalar(*ElementType, self.objects.items, object) == null) {
                try self.objects.append(self.allocator, object);
            }
        }

        pub fn removeObject(self: *Self, object: *ElementType) !void {
            if (std.mem.indexOfScalar(*ElementType, self.objects.items, object)) |index| {
                _ = self.objects.swapRemove(index);
            }
        }

        pub fn getObjectsInBoundBox(self: *Self, _: BoundBox(f32)) []*ElementType {
            return self.objects.items;
        }

        pub fn getLastGetObjectsInBoundBoxStats(_: *const Self) struct { invocations_count: u32, active_space_nodes_count: u32 } {
            return .{ .invocations_count = 1, .active_space_nodes_count = 0 };
        }
    };
}

test "unbounded queries return every object once and track removal" {
    const tree = try SpaceTree([3]f32).init(std.testing.allocator);
    defer tree.deinit();
    var far = [3]f32{ 1000000, -1000000, 1000000 };
    var near = [3]f32{ 0, 0, 0 };
    try tree.addObject(&far);
    try tree.addObject(&near);
    try tree.addObject(&far);
    const query: BoundBox(f32) = .{ .x = .init(-1e9, -1e9 + 100), .y = .init(1e9, 1e9 + 100), .z = .init(0, 1) };
    try std.testing.expectEqual(2, tree.getObjectsInBoundBox(query).len);
    try tree.removeObject(&far);
    try tree.removeObject(&far);
    try std.testing.expectEqualSlices(*[3]f32, &.{&near}, tree.getObjectsInBoundBox(query));
    try tree.removeObject(&near);
    try std.testing.expectEqual(0, tree.getObjectsInBoundBox(query).len);
}
