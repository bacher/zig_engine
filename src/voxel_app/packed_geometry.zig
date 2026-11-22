//! Camera-independent packed cargo sources. A warehouse cut supplies both goods
//! and empty-base markers; neither the terrain surface nor a pallet owns inventory.
const std = @import("std");
const engine = @import("engine");
const renderer = engine.packed_renderer;
const voxel = engine.voxel_chunk;
const client = @import("warehouse_client.zig");
const layout = @import("warehouse_layout.zig");
const ChunkId = @import("consts.zig").ChunkId;
const stream = @import("warehouse_stream.zig");

pub const Geometry = struct {
    groups: std.ArrayList(renderer.Group) = .empty,
    faces: std.ArrayList(renderer.Face) = .empty,
    models: std.ArrayList(renderer.Instance) = .empty,
    packaging: std.ArrayList(renderer.Instance) = .empty,
    pallets: std.ArrayList(renderer.Instance) = .empty,
    markers: std.ArrayList(renderer.Marker) = .empty,
    visited_objects: usize = 0,
    visited_slots: usize = 0,

    pub fn deinit(self: *Geometry, allocator: std.mem.Allocator) void {
        self.groups.deinit(allocator);
        self.faces.deinit(allocator);
        self.models.deinit(allocator);
        self.packaging.deinit(allocator);
        self.pallets.deinit(allocator);
        self.markers.deinit(allocator);
        self.* = .{};
    }

    pub fn bytes(self: Geometry) usize {
        return self.faces.items.len * @sizeOf(renderer.Face) +
            (self.models.items.len + self.packaging.items.len + self.pallets.items.len) * @sizeOf(renderer.Instance) +
            self.markers.items.len * @sizeOf(renderer.Marker);
    }

    pub fn allocatedBytes(self: Geometry) usize {
        return self.groups.capacity * @sizeOf(renderer.Group) + self.faces.capacity * @sizeOf(renderer.Face) +
            (self.models.capacity + self.packaging.capacity + self.pallets.capacity) * @sizeOf(renderer.Instance) +
            self.markers.capacity * @sizeOf(renderer.Marker);
    }

    fn counts(self: *const Geometry) @Vector(5, u32) {
        return .{ @intCast(self.faces.items.len), @intCast(self.models.items.len), @intCast(self.packaging.items.len), @intCast(self.pallets.items.len), @intCast(self.markers.items.len) };
    }

    fn finishGroup(self: *Geometry, allocator: std.mem.Allocator, box: renderer.Box, start: @Vector(5, u32)) !void {
        const added = self.counts() - start;
        if (@reduce(.Or, added != @as(@Vector(5, u32), @splat(0)))) try self.groups.append(allocator, .{ .box = box, .counts = added });
    }

    pub fn source(self: Geometry, chunk: engine.ChunkCoords, revision: u64) renderer.Source {
        return .{ .chunk = chunk, .revision = revision, .groups = self.groups.items, .faces = self.faces.items, .models = self.models.items, .packaging = self.packaging.items, .pallets = self.pallets.items, .markers = self.markers.items };
    }
};

pub const PalletFilter = struct {
    context: ?*const anyopaque = null,
    /// Null means a surface-only chunk: retain its authoritative auxiliary source.
    material_at: ?*const fn (?*const anyopaque, layout.Cell) ?voxel.BlockType = null,
};

fn localIndex(local: [3]u32) u15 {
    return @intCast(local[0] + 32 * local[1] + 1024 * local[2]);
}

fn localCell(index: u16) [3]u32 {
    return .{ index & 31, (index >> 5) & 31, index >> 10 };
}

fn inChunk(cell: layout.Cell, chunk: engine.ChunkCoords) bool {
    return cell[0] / 32 == chunk[0] and cell[1] / 32 == chunk[1] and cell[2] / 32 == chunk[2];
}

fn toLocal(cell: layout.Cell) [3]u32 {
    return .{ cell[0] % 32, cell[1] % 32, cell[2] % 32 };
}

/// Only references of this observed chunk are visited. The fixed-size occupancy
/// contract also culls faces through chunk boundaries and the wrapped-X seam.
pub fn buildChunk(allocator: std.mem.Allocator, cache: *const client.Cache, id: ChunkId, chunk: engine.ChunkCoords, pallet_indices: []const u16, extra_pallets: []const u16, filter: PalletFilter) !Geometry {
    return buildReferences(allocator, cache, cache.chunkReferences(id), chunk, pallet_indices, extra_pallets, filter);
}

pub fn buildReferences(allocator: std.mem.Allocator, cache: *const client.Cache, references: []const stream.Reference, chunk: engine.ChunkCoords, pallet_indices: []const u16, extra_pallets: []const u16, filter: PalletFilter) !Geometry {
    var result: Geometry = .{};
    errdefer result.deinit(allocator);
    var loose_pallets = std.StaticBitSet(32768).initEmpty();
    for ([_][]const u16{ pallet_indices, extra_pallets }) |indices| for (indices) |index| {
        if (index >= 32768) return error.InvalidPalletSource;
        const local = localCell(index);
        const cell: layout.Cell = .{ @as(u32, @intCast(chunk[0])) * 32 + local[0], @as(u32, @intCast(chunk[1])) * 32 + local[1], @as(u32, @intCast(chunk[2])) * 32 + local[2] };
        if (filter.material_at) |read| if (read(filter.context, cell)) |material| {
            if (material != .pallet) continue;
        };
        loose_pallets.set(index);
    };
    for (references) |reference| {
        const entry = cache.objects.get(reference.identity) orelse continue;
        if (entry.retired) continue;
        const start = result.counts();
        const bounds = reference.geometry.bounds;
        const order = entry.derived_layout;
        const stock = cache.record(reference.identity);
        // The one-cell border allows neighbor lookups on every exterior face.
        var occupied: [8][7][7]bool = @splat(@splat(@splat(false)));
        if (stock) |record| {
            result.visited_objects += 1;
            const irregular = record.material == .country_road_adaptive or record.material == .pallet;
            var slots: [layout.max_stock]layout.Offset = undefined;
            var index: u16 = 0;
            while (index < record.stock) : (index += 1) {
                const offset = order.slotAt(record.active, index).?;
                slots[index] = offset;
                occupied[@as(usize, @intCast(offset[2])) + 1][@as(usize, @intCast(offset[1] - bounds.ymin)) + 1][@as(usize, @intCast(offset[0] - bounds.xmin)) + 1] = true;
            }
            for (slots[0..record.stock]) |offset| {
                result.visited_slots += 1;
                const cell = record.geometry.worldCell(cache.world_size, offset).?;
                if (!inChunk(cell, chunk)) continue;
                const local = toLocal(cell);
                loose_pallets.unset(localIndex(local));
                if (irregular) {
                    const instance: renderer.Instance = .{ .local = local, .material = @intFromEnum(record.material) };
                    try result.models.append(allocator, instance);
                    try result.packaging.append(allocator, instance);
                    continue;
                }
                for (std.enums.values(voxel.Side)) |side| {
                    const direction = side.getOffset();
                    const x: usize = @intCast(@as(i32, offset[0] - bounds.xmin) + direction[0] + 1);
                    const y: usize = @intCast(@as(i32, offset[1] - bounds.ymin) + direction[1] + 1);
                    const z: usize = @intCast(@as(i32, offset[2]) + direction[2] + 1);
                    if (occupied[z][y][x]) continue;
                    try result.faces.append(allocator, .{ .local = local, .material = @intFromEnum(record.material), .direction = @intFromEnum(side) });
                }
            }
        }
        // Registration supplies the member pallets even before stock arrives.
        // An occupied base already has a pallet in its cargo geometry.
        for (order.columns[0..order.count], 0..) |column, rank| {
            const cell = reference.geometry.worldCell(cache.world_size, .{ column[0], column[1], 0 }).?;
            if (!inChunk(cell, chunk)) continue;
            const local = toLocal(cell);
            loose_pallets.unset(localIndex(local));
            const x: usize = @intCast(column[0] - bounds.xmin + 1);
            const y: usize = @intCast(column[1] - bounds.ymin + 1);
            if (occupied[1][y][x]) continue;
            try result.pallets.append(allocator, .{ .local = local, .material = @intFromEnum(voxel.BlockType.pallet) });
            if (stock) |record| try result.markers.append(allocator, .{ .local = local, .material = @intFromEnum(record.material), .disabled = @intFromBool(rank >= record.active) });
        }
        const minimum = reference.geometry.worldCell(cache.world_size, .{ bounds.xmin, bounds.ymin, 0 }).?;
        const box: renderer.Box = .{
            .chunk = .{ @intCast(minimum[0] / 32), @intCast(minimum[1] / 32), @intCast(minimum[2] / 32) },
            .local = .{ @intCast(minimum[0] % 32), @intCast(minimum[1] % 32), @intCast(minimum[2] % 32) },
            .extent = .{ bounds.width(), bounds.height(), layout.levels },
        };
        try result.finishGroup(allocator, box, start);
    }
    const loose_start = result.counts();
    var iterator = loose_pallets.iterator(.{});
    while (iterator.next()) |index| try result.pallets.append(allocator, .{ .local = localCell(@intCast(index)), .material = @intFromEnum(voxel.BlockType.pallet) });
    try result.finishGroup(allocator, renderer.Box.chunkBox(chunk), loose_start);
    return result;
}

pub const Limits = struct { chunks: u32 = 8192, pallet_indices: usize = 16 * 1024 * 1024 };
pub const Chunk = struct {
    subscription_id: u64,
    pallet_revision: u64,
    pallets: []const u16,
    revision: u64 = 1,
    dirty: bool = true,
    uploaded: bool = false,
    terrain_retained: bool = false,
    references: std.ArrayList(stream.Reference) = .empty,
};

/// Auxiliary sources survive surface/block promotions; a new subscription token can
/// replace them, while delayed replies and allocation failures cannot roll them back.
pub const Cache = struct {
    chunks: std.AutoHashMapUnmanaged(ChunkId, Chunk) = .empty,
    pallet_count: usize = 0,
    limits: Limits = .{},

    pub fn estimatedOwnedBytes(self: *const Cache) usize {
        var result: usize = @as(usize, self.chunks.capacity()) * (@sizeOf(ChunkId) + @sizeOf(Chunk) + 1);
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| result += chunk.pallets.len * @sizeOf(u16) + chunk.references.capacity * @sizeOf(stream.Reference);
        return result;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| {
            allocator.free(chunk.pallets);
            chunk.references.deinit(allocator);
        }
        self.chunks.deinit(allocator);
        self.* = .{};
    }

    pub fn installPallets(self: *Cache, allocator: std.mem.Allocator, id: ChunkId, token: u64, revision: u64, indices: []const u16) !bool {
        const old = self.chunks.get(id);
        if (old) |value| if (token < value.subscription_id or (token == value.subscription_id and revision < value.pallet_revision)) return false;
        if (indices.len > 32768) return error.InvalidPalletSource;
        for (indices) |index| if (index >= 32768) return error.InvalidPalletSource;
        const previous = if (old) |value| value.pallets.len else 0;
        if (indices.len > self.limits.pallet_indices -| (self.pallet_count - previous)) return error.PackedSourceCapacity;
        if (old == null and self.chunks.count() >= self.limits.chunks) return error.PackedSourceCapacity;
        if (old) |value| if (std.mem.eql(u16, value.pallets, indices)) {
            const chunk = self.chunks.getPtr(id).?;
            chunk.subscription_id = token;
            chunk.pallet_revision = revision;
            chunk.terrain_retained = token != 0;
            return true;
        };
        const copy = try allocator.dupe(u16, indices);
        errdefer allocator.free(copy);
        try self.chunks.ensureUnusedCapacity(allocator, @intFromBool(old == null));
        self.chunks.putAssumeCapacity(id, .{ .subscription_id = token, .pallet_revision = revision, .pallets = copy, .revision = if (old) |value| value.revision +% 1 else 1, .uploaded = if (old) |value| value.uploaded else false, .terrain_retained = token != 0, .references = if (old) |value| value.references else .empty });
        if (old) |value| allocator.free(value.pallets);
        self.pallet_count = self.pallet_count - previous + indices.len;
        return true;
    }

    pub fn mark(self: *Cache, id: ChunkId) void {
        if (self.chunks.getPtr(id)) |chunk| {
            chunk.revision +%= 1;
            chunk.dirty = true;
        }
    }

    pub fn remove(self: *Cache, allocator: std.mem.Allocator, id: ChunkId) void {
        var old = self.chunks.fetchRemove(id) orelse return;
        self.pallet_count -= old.value.pallets.len;
        allocator.free(old.value.pallets);
        old.value.references.deinit(allocator);
    }

    pub fn releaseTerrain(self: *Cache, allocator: std.mem.Allocator, id: ChunkId) void {
        const chunk = self.chunks.getPtr(id) orelse return;
        self.pallet_count -= chunk.pallets.len;
        allocator.free(chunk.pallets);
        chunk.pallets = &.{};
        chunk.terrain_retained = false;
        self.mark(id);
    }

    /// Atomically extend the bounded presentation directory to the whole saved
    /// footprint. No terrain residency or origin chunk is needed.
    pub fn retainObject(self: *Cache, allocator: std.mem.Allocator, world_layout: *const engine.WorldLayout, reference: stream.Reference) !void {
        const chunks = try @import("warehouse_claims.zig").chunks(world_layout.size_in_blocks, reference.geometry);
        var ids: [8]ChunkId = undefined;
        var additional: u32 = 0;
        for (chunks.coords[0..chunks.count], 0..) |coords, index| {
            ids[index] = world_layout.encodeChunkCoords(.{ @intCast(coords[0]), @intCast(coords[1]), @intCast(coords[2]) });
            if (!self.chunks.contains(ids[index])) additional += 1;
        }
        if (additional > self.limits.chunks -| self.chunks.count()) return error.PackedSourceCapacity;
        try self.chunks.ensureUnusedCapacity(allocator, additional);
        var inserted: [8]ChunkId = undefined;
        var inserted_count: usize = 0;
        errdefer for (inserted[0..inserted_count]) |id| self.remove(allocator, id);
        for (ids[0..chunks.count]) |id| {
            if (!self.chunks.contains(id)) {
                self.chunks.putAssumeCapacity(id, .{ .subscription_id = 0, .pallet_revision = 0, .pallets = &.{} });
                inserted[inserted_count] = id;
                inserted_count += 1;
            }
            const chunk = self.chunks.getPtr(id).?;
            var found = false;
            for (chunk.references.items) |existing| if (std.meta.eql(existing.identity, reference.identity)) {
                found = true;
                break;
            };
            if (!found) try chunk.references.ensureUnusedCapacity(allocator, 1);
        }
        for (ids[0..chunks.count]) |id| {
            const chunk = self.chunks.getPtr(id).?;
            var found = false;
            for (chunk.references.items) |existing| if (std.meta.eql(existing.identity, reference.identity)) {
                found = true;
                break;
            };
            if (!found) chunk.references.appendAssumeCapacity(reference);
            self.mark(id);
        }
    }

    pub fn releaseObject(self: *Cache, world_layout: *const engine.WorldLayout, reference: stream.Reference) void {
        const chunks = @import("warehouse_claims.zig").chunks(world_layout.size_in_blocks, reference.geometry) catch return;
        for (chunks.coords[0..chunks.count]) |coords| {
            const id = world_layout.encodeChunkCoords(.{ @intCast(coords[0]), @intCast(coords[1]), @intCast(coords[2]) });
            const chunk = self.chunks.getPtr(id) orelse continue;
            for (chunk.references.items, 0..) |existing, index| if (std.meta.eql(existing.identity, reference.identity)) {
                _ = chunk.references.swapRemove(index);
                self.mark(id);
                break;
            };
        }
    }
};

fn testWarehouse(allocator: std.mem.Allocator, material: voxel.BlockType, stock: u16, active: u8) !client.Cache {
    var result: client.Cache = .{ .world_size = .{ 128, 128, 128 } };
    errdefer result.deinit(allocator);
    _ = result.acceptSession(1);
    const record: @import("warehouse_state.zig").Record = .{
        .identity = .{ .kind = .warehouse, .world_session = 1, .id = 1, .lifetime = 1 },
        .geometry = try layout.Geometry.fromMinimum(result.world_size, .{ 30, 30, 31 }, .{ 5, 5 }),
        .material = material,
        .stock = stock,
        .active = active,
        .revision = 1,
    };
    _ = try result.installChunk(allocator, 1, 1, 1, &.{.{ .identity = record.identity, .geometry = record.geometry }});
    result.subscribed(record.identity, 1);
    _ = result.apply(.{ .snapshot = .{ .identity = record.identity, .record = record, .subscription_id = 1 } });
    return result;
}

test "packed external faces cull across chunks and keep irregular cargo in two batches" {
    const allocator = std.testing.allocator;
    for ([_]voxel.BlockType{ .dirt, .country_road_adaptive, .pallet }) |material| {
        var cache = try testWarehouse(allocator, material, 150, 25);
        defer cache.deinit(allocator);
        var faces: usize = 0;
        var models: usize = 0;
        var packaging: usize = 0;
        for (0..2) |z| for (0..2) |y| for (0..2) |x| {
            var built = try buildChunk(allocator, &cache, 1, .{ @intCast(x), @intCast(y), @intCast(z) }, &.{}, &.{}, .{});
            defer built.deinit(allocator);
            try std.testing.expectEqual(1, built.groups.items.len);
            const group = built.groups.items[0];
            try std.testing.expectEqual(renderer.Box{ .chunk = .{ 0, 0, 0 }, .local = .{ 30, 30, 31 }, .extent = .{ 5, 5, 6 } }, group.box);
            try std.testing.expectEqual(@as(@Vector(5, u32), group.counts), built.counts());
            faces += built.faces.items.len;
            models += built.models.items.len;
            packaging += built.packaging.items.len;
            try std.testing.expectEqual(@as(usize, 0), built.markers.items.len);
        };
        try std.testing.expectEqual(@as(usize, if (material == .dirt) 170 else 0), faces);
        try std.testing.expectEqual(@as(usize, if (material == .dirt) 0 else 150), models);
        try std.testing.expectEqual(models, packaging);
    }
}

test "packed markers require real empty bases and share the predicted cargo cut" {
    const allocator = std.testing.allocator;
    var cache = try testWarehouse(allocator, .dirt, 0, 24);
    defer cache.deinit(allocator);
    const indices = [_]u16{ 30 + 32 * 30 + 1024 * 31, 31 + 32 * 31 + 1024 * 31 };
    var empty = try buildChunk(allocator, &cache, 1, .{ 0, 0, 0 }, &indices, &.{}, .{});
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), empty.markers.items.len);
    try std.testing.expectEqual(@as(usize, 4), empty.pallets.items.len);
    try std.testing.expectEqual(1, empty.groups.items.len);
    try std.testing.expectEqual([3]u8{ 5, 5, 6 }, empty.groups.items[0].box.extent);
    try std.testing.expectEqual([5]u32{ 0, 0, 0, 4, 4 }, empty.groups.items[0].counts);
    const identity = cache.chunkReferences(1)[0].identity;
    const order = cache.objects.get(identity).?.derived_layout;
    const first = cache.objects.get(identity).?.geometry.worldCell(cache.world_size, order.slotAt(24, 0).?).?;
    const first_index = localIndex(toLocal(first));
    try cache.predict(allocator, .{ .request_id = 1, .command = .{ .world_session = 1, .client_session = 1, .sequence = 1 }, .identity = identity, .delta = 1, .material = .dirt });
    const coords: engine.ChunkCoords = .{ @intCast(first[0] / 32), @intCast(first[1] / 32), @intCast(first[2] / 32) };
    var occupied = try buildChunk(allocator, &cache, 1, coords, &.{first_index}, &.{}, .{});
    defer occupied.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6), occupied.faces.items.len);
    for (occupied.markers.items) |marker| try std.testing.expect(!std.meta.eql(marker.local, toLocal(first)));
    for (occupied.pallets.items) |pallet| try std.testing.expect(!std.meta.eql(pallet.local, toLocal(first)));
    cache.invalidate(identity);
    var unknown = try buildChunk(allocator, &cache, 1, coords, &.{first_index}, &.{}, .{});
    defer unknown.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), unknown.faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), unknown.markers.items.len);
    try std.testing.expectEqual(occupied.pallets.items.len + 1, unknown.pallets.items.len);
}

test "packed auxiliary sources retain latest tokens through surface block handoff" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    try std.testing.expect(try cache.installPallets(allocator, 1, 1, 5, &.{1}));
    cache.chunks.getPtr(1).?.dirty = false;
    try std.testing.expect(try cache.installPallets(allocator, 1, 2, 1, &.{1}));
    try std.testing.expect(!cache.chunks.get(1).?.dirty);
    try std.testing.expect(!try cache.installPallets(allocator, 1, 1, 20, &.{2}));
    try std.testing.expect(try cache.installPallets(allocator, 1, 2, 2, &.{}));
    try std.testing.expect(cache.chunks.get(1).?.dirty);
    try std.testing.expectEqual(@as(usize, 0), cache.pallet_count);
}

fn allocationSource(allocator: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = try cache.installPallets(allocator, 1, 1, 1, &.{1});
    _ = cache.installPallets(allocator, 1, 2, 2, &.{ 2, 3 }) catch |err| {
        try std.testing.expectEqual(@as(u64, 1), cache.chunks.get(1).?.subscription_id);
        try std.testing.expectEqualSlices(u16, &.{1}, cache.chunks.get(1).?.pallets);
        return err;
    };
}

test "packed source allocation failures retain previous complete presentation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationSource, .{});
}

fn allocationDirectory(allocator: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    const world_layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const identity: stream.Identity = .{ .kind = .warehouse, .world_session = 1, .id = 1, .lifetime = 1 };
    const reference: stream.Reference = .{ .identity = identity, .geometry = try layout.Geometry.fromMinimum(world_layout.size_in_blocks, .{ 30, 30, 31 }, .{ 5, 5 }) };
    cache.retainObject(allocator, &world_layout, reference) catch |err| {
        try std.testing.expectEqual(@as(u32, 0), cache.chunks.count());
        return err;
    };
    try std.testing.expectEqual(@as(u32, 8), cache.chunks.count());
}

test "packed complete-footprint directory allocation failures publish no partial references" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationDirectory, .{});
}
