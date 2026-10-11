//! Sparse per-chunk construction and scheduled transformation state.
const std = @import("std");
const transformations = @import("block_transformations.zig");
pub const BlockIndex = transformations.BlockIndex;

pub const Metadata = struct {
    timed: transformations.Queue = .{},
    /// Only player/service placements are revalidated after an edit. Generated terrain
    /// remains mineable without applying building rules to natural cliffs and hills.
    constructed: std.ArrayList(BlockIndex) = .empty,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        self.timed.deinit(allocator);
        self.constructed.deinit(allocator);
    }

    pub fn clone(self: Metadata, allocator: std.mem.Allocator) Metadata {
        var copy: Metadata = .{ .timed = self.timed.clone(allocator) };
        copy.constructed.appendSlice(allocator, self.constructed.items) catch @panic("OOM");
        return copy;
    }

    pub fn markConstructed(self: *Metadata, allocator: std.mem.Allocator, block: BlockIndex) void {
        if (std.mem.indexOfScalar(BlockIndex, self.constructed.items, block) == null)
            self.constructed.append(allocator, block) catch @panic("OOM");
    }

    pub fn remove(self: *Metadata, block: BlockIndex) void {
        self.timed.cancel(block);
        if (std.mem.indexOfScalar(BlockIndex, self.constructed.items, block)) |i|
            _ = self.constructed.swapRemove(i);
    }
};
