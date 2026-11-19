//! Rebuildable envelope discovery and claims. References contain geometry and
//! registration identity only; stock remains in the simulation's warehouse.
const std = @import("std");
const layout = @import("warehouse_layout.zig");
pub const Identity = @import("construction_state.zig").Identity;
pub const Cell = layout.Cell;
pub const Geometry = layout.Geometry;
pub const ChunkCoords = [3]u32;

pub const Reference = struct {
    identity: Identity,
    geometry: Geometry,

    pub fn containsMember(self: Reference, world_width: u32, cell: Cell) bool {
        return self.geometry.containsMember(self.geometry.relativeCell(world_width, cell) orelse return false);
    }

    pub fn containsBody(self: Reference, world_width: u32, cell: Cell) bool {
        return self.geometry.containsBody(self.geometry.relativeCell(world_width, cell) orelse return false);
    }

    pub fn containsEnvelope(self: Reference, world_width: u32, cell: Cell) bool {
        return self.geometry.containsEnvelope(self.geometry.relativeCell(world_width, cell) orelse return false);
    }
};

pub const Chunks = struct {
    coords: [8]ChunkCoords = undefined,
    count: u8 = 0,
};

pub fn cellChunk(cell: Cell) ChunkCoords {
    return .{ cell[0] / layout.chunk_size, cell[1] / layout.chunk_size, cell[2] / layout.chunk_size };
}

/// The full 7x7x6 maximum envelope intersects at most eight chunks.
pub fn chunks(world_size: Cell, geometry: Geometry) layout.Error!Chunks {
    try geometry.validate(world_size);
    var result: Chunks = .{};
    var z: i8 = 0;
    while (z < layout.levels) : (z += 1) {
        var y = geometry.bounds.ymin - 1;
        while (y <= geometry.bounds.ymax + 1) : (y += 1) {
            var x = geometry.bounds.xmin - 1;
            while (x <= geometry.bounds.xmax + 1) : (x += 1) {
                const coord = cellChunk(geometry.worldCell(world_size, .{ x, y, z }).?);
                var found = false;
                for (result.coords[0..result.count]) |existing| {
                    if (std.meta.eql(existing, coord)) {
                        found = true;
                        break;
                    }
                }
                if (found) continue;
                std.debug.assert(result.count < result.coords.len);
                result.coords[result.count] = coord;
                result.count += 1;
            }
        }
    }
    return result;
}

fn bodyIntersectsEnvelope(world_size: Cell, body: Geometry, envelope: Geometry) bool {
    var z: i8 = 0;
    while (z < layout.levels) : (z += 1) {
        var y = body.bounds.ymin;
        while (y <= body.bounds.ymax) : (y += 1) {
            var x = body.bounds.xmin;
            while (x <= body.bounds.xmax) : (x += 1) {
                const cell = body.worldCell(world_size, .{ x, y, z }) orelse return true;
                const offset = envelope.relativeCell(world_size[0], cell) orelse continue;
                if (envelope.containsEnvelope(offset)) return true;
            }
        }
    }
    return false;
}

/// R36 is symmetric: only empty clearance halos may overlap.
pub fn compatible(world_size: Cell, a: Geometry, b: Geometry) bool {
    return !bodyIntersectsEnvelope(world_size, a, b) and !bodyIntersectsEnvelope(world_size, b, a);
}

pub const Index = struct {
    by_chunk: std.AutoHashMapUnmanaged(ChunkCoords, std.ArrayList(Reference)) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        var values = self.by_chunk.valueIterator();
        while (values.next()) |value| value.deinit(allocator);
        self.by_chunk.deinit(allocator);
        self.* = .{};
    }

    pub fn estimatedOwnedBytes(self: Index) usize {
        var result: usize = @as(usize, self.by_chunk.capacity()) * (@sizeOf(ChunkCoords) + @sizeOf(std.ArrayList(Reference)) + 1);
        var values = self.by_chunk.valueIterator();
        while (values.next()) |value| result += value.capacity * @sizeOf(Reference);
        return result;
    }

    pub fn chunkReferences(self: *const Index, coord: ChunkCoords) []const Reference {
        return if (self.by_chunk.get(coord)) |list| list.items else &.{};
    }

    pub fn cellReferences(self: *const Index, cell: Cell) []const Reference {
        return self.chunkReferences(cellChunk(cell));
    }

    pub fn bodyAt(self: *const Index, world_width: u32, cell: Cell) ?Reference {
        for (self.cellReferences(cell)) |reference| if (reference.containsBody(world_width, cell)) return reference;
        return null;
    }

    pub fn memberAt(self: *const Index, world_width: u32, cell: Cell) ?Reference {
        for (self.cellReferences(cell)) |reference| if (reference.containsMember(world_width, cell)) return reference;
        return null;
    }

    pub fn claimed(self: *const Index, world_width: u32, cell: Cell) bool {
        for (self.cellReferences(cell)) |reference| if (reference.containsEnvelope(world_width, cell)) return true;
        return false;
    }

    pub fn canInsert(self: *const Index, world_size: Cell, geometry: Geometry) layout.Error!bool {
        const touched = try chunks(world_size, geometry);
        for (touched.coords[0..touched.count]) |coord| {
            for (self.chunkReferences(coord)) |reference| {
                if (!compatible(world_size, geometry, reference.geometry)) return false;
            }
        }
        return true;
    }

    /// Allocation may grow empty index containers, but no reference is published
    /// until every append is guaranteed to succeed.
    pub fn insert(self: *Index, allocator: std.mem.Allocator, world_size: Cell, reference: Reference) !void {
        const touched = try chunks(world_size, reference.geometry);
        try self.by_chunk.ensureUnusedCapacity(allocator, touched.count);
        var created: [8]ChunkCoords = undefined;
        var created_count: usize = 0;
        errdefer {
            for (created[0..created_count]) |coord| {
                var removed = self.by_chunk.fetchRemove(coord).?.value;
                std.debug.assert(removed.items.len == 0);
                removed.deinit(allocator);
            }
        }
        for (touched.coords[0..touched.count]) |coord| {
            const entry = self.by_chunk.getOrPutAssumeCapacity(coord);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
                created[created_count] = coord;
                created_count += 1;
            }
            for (entry.value_ptr.items) |existing| if (existing.identity.eql(reference.identity)) return error.DuplicateRegistration;
            try entry.value_ptr.ensureTotalCapacityPrecise(allocator, entry.value_ptr.items.len + 1);
        }
        for (touched.coords[0..touched.count]) |coord| self.by_chunk.getPtr(coord).?.appendAssumeCapacity(reference);
    }

    pub fn remove(self: *Index, allocator: std.mem.Allocator, world_size: Cell, reference: Reference) void {
        const touched = chunks(world_size, reference.geometry) catch unreachable;
        for (touched.coords[0..touched.count]) |coord| {
            const list = self.by_chunk.getPtr(coord) orelse unreachable;
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (!list.items[i].identity.eql(reference.identity)) continue;
                _ = list.swapRemove(i);
                break;
            }
            if (list.items.len == 0) {
                list.deinit(allocator);
                _ = self.by_chunk.remove(coord);
            }
        }
    }
};

test "warehouse shared aisle claims survive independent retirement and wrapped X" {
    const allocator = std.testing.allocator;
    const size: Cell = .{ 128, 128, 128 };
    const a = try Geometry.fromMinimum(size, .{ 127, 20, 31 }, .{ 1, 1 });
    const b = try Geometry.fromMinimum(size, .{ 1, 20, 31 }, .{ 1, 1 });
    const adjacent = try Geometry.fromMinimum(size, .{ 0, 20, 31 }, .{ 1, 1 });
    try std.testing.expect(compatible(size, a, b));
    try std.testing.expect(compatible(size, b, a));
    try std.testing.expect(!compatible(size, a, adjacent));
    var index: Index = .{};
    defer index.deinit(allocator);
    const ra: Reference = .{ .identity = .{ .world_session = 1, .kind = .warehouse, .id = 1, .lifetime = 1 }, .geometry = a };
    const rb: Reference = .{ .identity = .{ .world_session = 1, .kind = .warehouse, .id = 2, .lifetime = 2 }, .geometry = b };
    try index.insert(allocator, size, ra);
    try index.insert(allocator, size, rb);
    try std.testing.expect(index.claimed(size[0], .{ 0, 20, 31 }));
    try std.testing.expect(index.bodyAt(size[0], .{ 0, 20, 31 }) == null);
    try std.testing.expectEqualDeep(ra, index.memberAt(size[0], .{ 127, 20, 31 }).?);
    index.remove(allocator, size, ra);
    try std.testing.expect(index.claimed(size[0], .{ 0, 20, 31 }));
    try std.testing.expect(index.memberAt(size[0], .{ 127, 20, 31 }) == null);
    index.remove(allocator, size, rb);
    try std.testing.expect(!index.claimed(size[0], .{ 0, 20, 31 }));
}

test "warehouse full envelope has at most eight identity-only chunk references at every alignment" {
    const size: Cell = .{ 128, 128, 128 };
    for (0..32) |x| for (0..32) |y| for (0..32) |z| {
        const geometry = try Geometry.fromMinimum(size, .{ @intCast(96 + x), @intCast(32 + y), @intCast(32 + z) }, .{ 5, 5 });
        const touched = try chunks(size, geometry);
        try std.testing.expect(touched.count <= 8);
        const top = geometry.worldCell(size, .{ geometry.bounds.xmax + 1, geometry.bounds.ymax + 1, 5 }).?;
        var found = false;
        for (touched.coords[0..touched.count]) |coord| if (std.meta.eql(coord, cellChunk(top))) {
            found = true;
        };
        try std.testing.expect(found);
    };
}

test "warehouse failed disjoint claim admissions retain no empty index entries" {
    const allocator = std.testing.allocator;
    const size: Cell = .{ 8192, 128, 128 };
    var index: Index = .{};
    defer index.deinit(allocator);
    try index.by_chunk.ensureUnusedCapacity(allocator, 8);
    const initial_capacity = index.by_chunk.capacity();
    for (0..64) |attempt| for (0..8) |fail_at| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_at });
        const geometry = try Geometry.fromMinimum(size, .{ @intCast(31 + 64 * attempt), 31, 31 }, .{ 5, 5 });
        const reference: Reference = .{ .identity = .{ .world_session = 1, .kind = .warehouse, .id = attempt + 1, .lifetime = attempt + 1 }, .geometry = geometry };
        try std.testing.expectError(error.OutOfMemory, index.insert(failing.allocator(), size, reference));
        try std.testing.expectEqual(@as(u32, 0), index.by_chunk.count());
        try std.testing.expectEqual(initial_capacity, index.by_chunk.capacity());
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    };
}
