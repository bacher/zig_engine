//! A hierarchy of occupied chunk bounds, shared by perspective and orthographic passes.
const std = @import("std");
const zm = @import("zmath");
const WorldLayout = @import("world_layout.zig").WorldLayout;
const Coord = @import("world_math.zig").ChunkCoords;
const size = @import("chunk_utils.zig").CHUNK_SIZE;

pub const InstanceRange = struct {
    first: u32 = std.math.maxInt(u32),
    end: u32 = 0,

    pub fn include(self: *InstanceRange, first: u32, end: u32) void {
        if (first >= end) return;
        self.first = @min(self.first, first);
        self.end = @max(self.end, end);
    }
};

pub const Relation = enum { outside, intersecting, inside };

pub const View = struct {
    layout: *const WorldLayout,
    origin: Coord,
    planes: [6]Plane,

    const Plane = struct {
        equation: zm.Vec,
        roundoff: zm.Vec,

        fn init(a: zm.Vec, b: zm.Vec) Plane {
            // The GPU evaluates two separate clip coordinates before comparing
            // them. Preserve their rounding allowance, especially for w-z.
            return .{ .equation = a + b, .roundoff = (@abs(a) + @abs(b)) * @as(zm.Vec, @splat(8 * std.math.floatEps(f32))) };
        }
    };

    pub fn init(layout: *const WorldLayout, origin: Coord, clip: zm.Mat) View {
        const x, const y, const z, const w = zm.transpose(clip);
        // WebGPU clip volume: -w <= x,y <= w and 0 <= z <= w.
        return .{ .layout = layout, .origin = origin, .planes = .{
            Plane.init(w, x), Plane.init(w, -x), Plane.init(w, y), Plane.init(w, -y), Plane.init(z, @splat(0)), Plane.init(w, -z),
        } };
    }

    pub fn classify(self: *const View, lo: zm.Vec, hi: zm.Vec) Relation {
        var relation: Relation = .inside;
        const magnitude = @max(@abs(lo), @abs(hi));
        for (self.planes) |plane| {
            const positive = plane.equation >= @as(zm.Vec, @splat(0));
            const allowance = @reduce(.Add, plane.roundoff * magnitude);
            if (@reduce(.Add, plane.equation * @select(f32, positive, hi, lo)) < -allowance) return .outside;
            if (@reduce(.Add, plane.equation * @select(f32, positive, lo, hi)) <= allowance) relation = .intersecting;
        }
        return relation;
    }

    pub fn chunkOffset(self: *const View, chunk: Coord) zm.Vec {
        return metres(self.layout.getChunkDelta(chunk, self.origin));
    }

    fn metres(delta: @Vector(3, i64)) zm.Vec {
        return .{ @floatFromInt(delta[0] * size), @floatFromInt(delta[1] * size), @floatFromInt(delta[2] * size), 1 };
    }

    fn chunks(self: *const View, min: Coord, max: Coord) Relation {
        var low = self.layout.getChunkDelta(min, self.origin);
        var high = self.layout.getChunkDelta(max, self.origin);
        // Canonical x is monotone except at the antipode. A node spanning
        // that cut must enclose both nearest images until its children split.
        if (WorldLayout.wrap_x and low[0] > high[0]) {
            high[0] = @divExact(self.layout.size_in_chunks[0], 2);
            low[0] = -high[0];
        }
        return self.classify(metres(low), metres(high) + zm.Vec{ size, size, size, 0 });
    }
};

pub fn Index(comptime Id: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { coord: Coord, id: Id };
        const Node = struct { lo: Coord, hi: Coord, start: usize, end: usize, right: usize = 0 };
        pub const Hit = struct { id: Id, inside: bool };

        entries: std.ArrayList(Entry) = .empty,
        nodes: std.ArrayList(Node) = .empty,
        hits: std.ArrayList(Hit) = .empty,
        dirty: bool = true,
        x_mask: u32 = 0,
        tested_nodes: usize = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.nodes.deinit(allocator);
            self.hits.deinit(allocator);
        }

        pub fn needsBuild(self: *const Self, layout: *const WorldLayout) bool {
            return self.dirty or (WorldLayout.wrap_x and self.x_mask != layout.id_masks[0]);
        }

        pub fn reserve(self: *Self, allocator: std.mem.Allocator, count: usize) !void {
            try self.entries.ensureTotalCapacity(allocator, count);
            try self.nodes.ensureTotalCapacity(allocator, 2 * count);
            try self.hits.ensureTotalCapacity(allocator, count);
        }

        pub fn begin(self: *Self, allocator: std.mem.Allocator, layout: *const WorldLayout, count: usize) !void {
            try self.reserve(allocator, count);
            self.x_mask = layout.id_masks[0];
            self.entries.clearRetainingCapacity();
            self.nodes.clearRetainingCapacity();
        }

        pub fn add(self: *Self, coord: Coord, id: Id) void {
            var key = coord;
            if (WorldLayout.wrap_x) key[0] = @intCast(@as(u32, @bitCast(coord[0])) & self.x_mask);
            self.entries.appendAssumeCapacity(.{ .coord = key, .id = id });
        }

        pub fn finish(self: *Self) void {
            if (self.entries.items.len != 0) self.build(0, self.entries.items.len);
            self.dirty = false;
        }

        fn build(self: *Self, start: usize, end: usize) void {
            const entries = self.entries.items[start..end];
            var lo = entries[0].coord;
            var hi = lo;
            for (entries[1..]) |entry| {
                lo = @min(lo, entry.coord);
                hi = @max(hi, entry.coord);
            }
            const node = self.nodes.items.len;
            self.nodes.appendAssumeCapacity(.{ .lo = lo, .hi = hi, .start = start, .end = end });
            if (entries.len <= 4 or @reduce(.And, lo == hi)) return;
            const span: [3]i64 = @as(@Vector(3, i64), hi) - @as(@Vector(3, i64), lo);
            var axis: usize = 0;
            for (1..3) |i| if (span[i] > span[axis]) {
                axis = i;
            };
            // Split the longest spatial extent. Both sides contain an extremum,
            // even for sparse outliers or several render layers at one coordinate.
            const lower: [3]i32 = lo;
            const split = lower[axis] + @divTrunc(span[axis], 2);
            var mid = start;
            for (start..end) |i| {
                const coord: [3]i32 = self.entries.items[i].coord;
                if (coord[axis] <= split) {
                    std.mem.swap(Entry, &self.entries.items[mid], &self.entries.items[i]);
                    mid += 1;
                }
            }
            self.build(start, mid);
            self.nodes.items[node].right = self.nodes.items.len;
            self.build(mid, end);
        }

        /// The scratch result lasts until the next query on this index.
        pub fn query(self: *Self, view: *const View) []const Hit {
            std.debug.assert(!self.needsBuild(view.layout));
            self.hits.clearRetainingCapacity();
            self.tested_nodes = 0;
            if (self.nodes.items.len != 0) self.visit(0, view);
            return self.hits.items;
        }

        fn visit(self: *Self, index: usize, view: *const View) void {
            const node = self.nodes.items[index];
            self.tested_nodes += 1;
            const relation = view.chunks(node.lo, node.hi);
            if (relation == .outside) return;
            if (relation == .intersecting and node.right != 0) {
                self.visit(index + 1, view);
                self.visit(node.right, view);
                return;
            }
            // Layers sharing one chunk share its classification.
            const shared = relation == .inside or @reduce(.And, node.lo == node.hi);
            for (self.entries.items[node.start..node.end]) |entry| {
                const r = if (shared) relation else view.chunks(entry.coord, entry.coord);
                if (r != .outside) self.hits.appendAssumeCapacity(.{ .id = entry.id, .inside = r == .inside });
            }
        }
    };
}
