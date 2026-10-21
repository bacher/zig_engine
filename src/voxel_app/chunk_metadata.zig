//! Sparse per-chunk construction and scheduled transformation state.
const std = @import("std");
const transformations = @import("block_transformations.zig");
pub const BlockIndex = transformations.BlockIndex;

pub const Metadata = struct {
    roads: std.ArrayList(@import("road_data.zig").Road) = .empty,
    timed: transformations.Queue = .{},
    /// Only player/service placements are revalidated after an edit. Generated terrain
    /// remains mineable without applying building rules to natural cliffs and hills.
    constructed: std.ArrayList(BlockIndex) = .empty,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        self.roads.deinit(allocator);
        self.timed.deinit(allocator);
        self.constructed.deinit(allocator);
    }

    pub fn tryClone(self: Metadata, allocator: std.mem.Allocator) !Metadata {
        var copy: Metadata = .{};
        errdefer copy.deinit(allocator);
        copy.timed = try self.timed.tryClone(allocator);
        try copy.roads.appendSlice(allocator, self.roads.items);
        try copy.constructed.appendSlice(allocator, self.constructed.items);
        return copy;
    }

    pub fn clone(self: Metadata, allocator: std.mem.Allocator) Metadata {
        return self.tryClone(allocator) catch @panic("OOM");
    }

    /// Capacity-only preparation; no collection contents change on failure.
    pub fn reserve(self: *Metadata, allocator: std.mem.Allocator, road_additional: usize, constructed_additional: usize, timer_additional: usize) !void {
        try self.roads.ensureUnusedCapacity(allocator, road_additional);
        try self.constructed.ensureUnusedCapacity(allocator, constructed_additional);
        try self.timed.reserve(allocator, timer_additional);
    }

    pub fn markConstructedAssumeCapacity(self: *Metadata, block: BlockIndex) void {
        if (std.mem.indexOfScalar(BlockIndex, self.constructed.items, block) == null)
            self.constructed.appendAssumeCapacity(block);
    }

    pub fn tryMarkConstructed(self: *Metadata, allocator: std.mem.Allocator, block: BlockIndex) !void {
        if (std.mem.indexOfScalar(BlockIndex, self.constructed.items, block) == null) {
            try self.constructed.ensureUnusedCapacity(allocator, 1);
            self.constructed.appendAssumeCapacity(block);
        }
    }

    pub fn markConstructed(self: *Metadata, allocator: std.mem.Allocator, block: BlockIndex) void {
        self.tryMarkConstructed(allocator, block) catch @panic("OOM");
    }

    pub fn remove(self: *Metadata, block: BlockIndex) void {
        for (self.roads.items, 0..) |entry, i| if (entry.index == block) {
            _ = self.roads.swapRemove(i);
            break;
        };
        self.timed.cancel(block);
        if (std.mem.indexOfScalar(BlockIndex, self.constructed.items, block)) |i|
            _ = self.constructed.swapRemove(i);
    }

    pub fn road(self: *const Metadata, block: BlockIndex) ?@import("road_data.zig").Road {
        for (self.roads.items) |entry| if (entry.index == block) return entry;
        return null;
    }

    pub fn roadPtr(self: *Metadata, block: BlockIndex) ?*@import("road_data.zig").Road {
        for (self.roads.items) |*entry| if (entry.index == block) return entry;
        return null;
    }
};

fn exerciseFallibleMetadata(a: std.mem.Allocator) !void {
    var source: Metadata = .{};
    defer source.deinit(a);
    try source.reserve(a, 1, 1, 1);
    source.roads.appendAssumeCapacity(.{ .index = 4 });
    source.markConstructedAssumeCapacity(4);
    source.timed.scheduleAssumeCapacity(.{ .block = 4, .kind = .grow_grass, .due_tick = 44 });
    var copy = try source.tryClone(a);
    defer copy.deinit(a);
    try copy.tryMarkConstructed(a, 5);
    try std.testing.expectEqual(@as(usize, 1), source.constructed.items.len);
    try std.testing.expectEqual(@as(usize, 2), copy.constructed.items.len);
    try std.testing.expectEqual(@as(u64, 44), copy.timed.events.items[0].due_tick);
}
test "fallible metadata preparation and cloning clean up all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFallibleMetadata, .{});
}
