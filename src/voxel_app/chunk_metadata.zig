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

    pub fn clone(self: Metadata, allocator: std.mem.Allocator) Metadata {
        var copy: Metadata = .{ .timed = self.timed.clone(allocator) };
        copy.roads.appendSlice(allocator, self.roads.items) catch @panic("OOM");
        copy.constructed.appendSlice(allocator, self.constructed.items) catch @panic("OOM");
        return copy;
    }

    pub fn markConstructed(self: *Metadata, allocator: std.mem.Allocator, block: BlockIndex) void {
        if (std.mem.indexOfScalar(BlockIndex, self.constructed.items, block) == null)
            self.constructed.append(allocator, block) catch @panic("OOM");
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
