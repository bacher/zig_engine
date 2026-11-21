//! Draw a retained group as one spatial object, including its pieces in other chunks.
const std = @import("std");
const vis = @import("chunk_visibility.zig");
const Coord = @import("world_math.zig").ChunkCoords;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const size = @import("chunk_utils.zig").CHUNK_SIZE;

pub const categories = 5;
pub const Counts = [categories]u32;

/// Storage cells. A wrapped box starts at its canonical minimum and continues
/// towards positive x. It may end across the world seam.
pub const Box = struct {
    chunk: [3]i32,
    local: [3]u8,
    extent: [3]u8,

    pub fn chunkBox(chunk: Coord) Box {
        return .{ .chunk = chunk, .local = @splat(0), .extent = @splat(size) };
    }

    fn lastChunk(box: Box) Coord {
        var result: Coord = box.chunk;
        inline for (0..3) |i| result[i] += @divFloor(@as(i32, box.local[i]) + box.extent[i] - 1, size);
        return result;
    }

    pub fn chunkCount(box: Box) usize {
        return @intCast(@reduce(.Mul, box.lastChunk() - @as(Coord, box.chunk) + @as(Coord, @splat(1))));
    }

    fn visible(box: Box, view: *const vis.View) bool {
        const last = box.lastChunk();
        const start = view.chunkOffset(box.chunk);
        var lo = start;
        var hi = view.chunkOffset(last);
        inline for (0..3) |i| {
            lo[i] += @floatFromInt(box.local[i]);
            hi[i] += @floatFromInt((@as(u32, box.local[i]) + box.extent[i] - 1) % size + 1);
        }
        if (lo[0] > hi[0]) {
            // Adjacent chunks can be drawn on opposite sides of the camera at
            // the antipode. Test the two pieces in their actual shader images.
            var left_hi = hi;
            left_hi[0] = start[0] + size;
            var right_lo = lo;
            right_lo[0] = view.chunkOffset(last)[0];
            return view.classify(lo, left_hi) != .outside or view.classify(right_lo, hi) != .outside;
        }
        return view.classify(lo, hi) != .outside;
    }

    pub fn valid(box: Box) bool {
        inline for (0..3) |i| {
            if (box.local[i] >= size or box.extent[i] == 0 or box.extent[i] > size) return false;
            if (box.chunk[i] == std.math.maxInt(i32) and @as(u32, box.local[i]) + box.extent[i] > size) return false;
        }
        return true;
    }
};

/// Successive runs in each source category. All pieces of the same box
/// participate in one visibility decision, including cross-chunk warehouses.
pub const Group = struct { box: Box, counts: Counts };
pub const CachedGroup = struct { box: Box, counts: Counts, runs: [categories][]const vis.InstanceRange = @splat(&.{}) };
const Piece = struct { source: u64, group: usize, next: ?usize };
const LogicalGroup = struct { head: ?usize = null, visited: bool = false };

pub const Plan = struct {
    index: vis.ContainmentIndex(usize) = .{},
    groups: std.array_hash_map.Auto(Box, LogicalGroup) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    visible_groups: std.ArrayList(*const CachedGroup) = .empty,

    pub fn deinit(self: *Plan, a: std.mem.Allocator) void {
        self.index.deinit(a);
        self.groups.deinit(a);
        self.pieces.deinit(a);
        self.visible_groups.deinit(a);
    }

    pub fn capacityBytes(self: *const Plan) usize {
        return self.index.capacityBytes() + self.groups.capacity() * (@sizeOf(Box) + @sizeOf(LogicalGroup)) +
            self.pieces.capacity * @sizeOf(Piece) + self.visible_groups.capacity * @sizeOf(*const CachedGroup);
    }

    pub fn reserve(self: *Plan, a: std.mem.Allocator, n: usize, cells: usize) !void {
        try self.index.reserve(a, cells);
        try self.groups.ensureTotalCapacity(a, n);
        try self.pieces.ensureTotalCapacity(a, n);
        try self.visible_groups.ensureTotalCapacity(a, n);
    }

    pub fn rebuild(self: *Plan, layout: *const WorldLayout, sources: anytype) void {
        self.index.reset(layout);
        self.groups.clearRetainingCapacity();
        self.pieces.clearRetainingCapacity();
        var iter = sources.iterator();
        while (iter.next()) |source| {
            for (source.value_ptr.groups, 0..) |group, i| {
                const entry = self.groups.getOrPutAssumeCapacity(group.box);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                self.pieces.appendAssumeCapacity(.{ .source = source.key_ptr.*, .group = i, .next = entry.value_ptr.head });
                entry.value_ptr.head = self.pieces.items.len - 1;
            }
        }
        for (self.groups.keys(), 0..) |box, i| {
            const last = box.lastChunk();
            const span = last - @as(Coord, box.chunk) + @as(Coord, @splat(1));
            for (0..@intCast(span[2])) |z| for (0..@intCast(span[1])) |y| for (0..@intCast(span[0])) |x| {
                self.index.add(@as(Coord, box.chunk) + Coord{ @intCast(x), @intCast(y), @intCast(z) }, i);
            };
        }
        self.index.finish();
    }

    /// The result borrows source groups for the duration of the current draw.
    pub fn query(self: *Plan, view: *const vis.View, sources: anytype) []const *const CachedGroup {
        if (self.index.needsBuild(view.layout)) self.rebuild(view.layout, sources);
        self.visible_groups.clearRetainingCapacity();
        const hits = self.index.query(view);
        for (hits) |hit| self.groups.values()[hit.id].visited = false;
        for (hits) |hit| {
            const group = &self.groups.values()[hit.id];
            if (group.visited) continue;
            group.visited = true;
            if (!hit.inside and !self.groups.keys()[hit.id].visible(view)) continue;
            var next = group.head;
            while (next) |i| {
                const piece = self.pieces.items[i];
                self.visible_groups.appendAssumeCapacity(&sources.getPtr(piece.source).?.groups[piece.group]);
                next = piece.next;
            }
        }
        return self.visible_groups.items;
    }
};
