//! Construction publication is independent of terrain representation. Snapshots
//! establish a revision; deltas are meaningful only against that exact revision.
const std = @import("std");
const runtime = @import("blueprint_runtime.zig");
pub const Identity = @import("construction_state.zig").Identity;
pub const Phase = runtime.Phase;
pub const ChunkId = @import("consts.zig").ChunkId;

pub const Snapshot = struct {
    identity: Identity,
    id: u64,
    definition_id: u64,
    owner: u64,
    origin: runtime.Cell,
    rotation: u2,
    fulfilled: []const u8,
    remaining: u32,
    active: bool = true,
    phase: Phase = .building,
    revision: u64 = 0,
    lifetime: u64 = 0,
    box_chunks: []const ChunkId,
    target_groups: []const runtime.TargetGroup = &.{},
    target_indices: []const u32 = &.{},
    remaining_groups: u32 = 0,

    /// Borrows the publisher's arrays until its next mutation. Clone before
    /// queuing or retaining this view; only an owned clone may be deinitialized.
    /// Executor-local bookkeeping deliberately has no transport field.
    pub fn borrow(identity: Identity, instance: runtime.Instance) Snapshot {
        return .{
            .identity = identity,
            .id = instance.id,
            .definition_id = instance.definition_id,
            .owner = instance.owner,
            .origin = instance.origin,
            .rotation = instance.rotation,
            .fulfilled = instance.fulfilled,
            .remaining = instance.remaining,
            .active = instance.active,
            .phase = instance.phase,
            .revision = instance.revision,
            .lifetime = instance.lifetime,
            .box_chunks = instance.box_chunks,
            .target_groups = instance.target_groups,
            .target_indices = instance.target_indices,
            .remaining_groups = instance.remaining_groups,
        };
    }

    pub fn estimatedOwnedBytes(self: Snapshot) usize {
        return self.fulfilled.len +| self.box_chunks.len *| @sizeOf(ChunkId) +|
            self.target_groups.len *| @sizeOf(runtime.TargetGroup) +| self.target_indices.len *| @sizeOf(u32);
    }

    /// Returns an independent, owned publication with immutable array views.
    pub fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        var copy = self;
        copy.fulfilled = try allocator.dupe(u8, self.fulfilled);
        errdefer allocator.free(copy.fulfilled);
        copy.box_chunks = try allocator.dupe(ChunkId, self.box_chunks);
        errdefer allocator.free(copy.box_chunks);
        copy.target_groups = try allocator.dupe(runtime.TargetGroup, self.target_groups);
        errdefer allocator.free(copy.target_groups);
        copy.target_indices = try allocator.dupe(u32, self.target_indices);
        return copy;
    }

    /// Creates one owned runtime copy for validation and atomic installation.
    /// The fresh allocations become mutable only within the receiving runtime;
    /// retirement progress starts at its local default, never the publisher's.
    pub fn toInstance(self: Snapshot, allocator: std.mem.Allocator) !runtime.Instance {
        const copy = try self.clone(allocator);
        return .{
            .id = copy.id,
            .definition_id = copy.definition_id,
            .owner = copy.owner,
            .origin = copy.origin,
            .rotation = copy.rotation,
            .fulfilled = @constCast(copy.fulfilled),
            .remaining = copy.remaining,
            .active = copy.active,
            .phase = copy.phase,
            .revision = copy.revision,
            .lifetime = copy.lifetime,
            .box_chunks = @constCast(copy.box_chunks),
            .target_groups = @constCast(copy.target_groups),
            .target_indices = @constCast(copy.target_indices),
            .remaining_groups = copy.remaining_groups,
        };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.fulfilled);
        allocator.free(self.box_chunks);
        allocator.free(self.target_groups);
        allocator.free(self.target_indices);
        self.* = undefined;
    }
};

pub const Delta = struct {
    identity: Identity,
    base_revision: u64,
    revision: u64,
    /// Stable indices into the immutable definition's complete cell array.
    fulfilled_indices: []const u32 = &.{},
    phase: ?Phase = null,
    transfers: []const runtime.Transfer = &.{},

    pub fn clone(self: Delta, allocator: std.mem.Allocator) !Delta {
        const indices = try allocator.dupe(u32, self.fulfilled_indices);
        errdefer allocator.free(indices);
        return .{
            .identity = self.identity,
            .base_revision = self.base_revision,
            .revision = self.revision,
            .fulfilled_indices = indices,
            .phase = self.phase,
            .transfers = try allocator.dupe(runtime.Transfer, self.transfers),
        };
    }

    pub fn deinit(self: *Delta, allocator: std.mem.Allocator) void {
        allocator.free(self.fulfilled_indices);
        allocator.free(self.transfers);
        self.* = undefined;
    }
};

pub const Retirement = struct { identity: Identity, revision: u64, composition_revision: u64 = 0 };

pub const Update = union(enum) {
    snapshot: Snapshot,
    delta: Delta,
    retired: Retirement,

    pub fn clone(self: Update, allocator: std.mem.Allocator) !Update {
        return switch (self) {
            .snapshot => |value| .{ .snapshot = try value.clone(allocator) },
            .delta => |value| .{ .delta = try value.clone(allocator) },
            .retired => |value| .{ .retired = value },
        };
    }

    pub fn deinit(self: *Update, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .snapshot => |*value| value.deinit(allocator),
            .delta => |*value| value.deinit(allocator),
            .retired => {},
        }
        self.* = undefined;
    }
};

/// Discovery covers the active box, including chunks containing only cavities.
/// `transferred` selects the physical owner of this chunk's targets; it never
/// releases the box restrictions. A zero terrain revision is a valid version.
pub const SiteRef = struct {
    identity: Identity,
    site_revision: u64,
    transferred: bool = false,
    terrain_revision: u64 = 0,
};

/// Attached to blocks, mesh-only and empty/unreachable publications alike. The
/// revision orders discovery/transfer changes independently of block contents.
pub const ChunkComposition = struct {
    revision: u64 = 0,
    sites: []const SiteRef = &.{},

    pub fn clone(self: ChunkComposition, allocator: std.mem.Allocator) !ChunkComposition {
        return .{ .revision = self.revision, .sites = try allocator.dupe(SiteRef, self.sites) };
    }

    pub fn deinit(self: *ChunkComposition, allocator: std.mem.Allocator) void {
        allocator.free(self.sites);
        self.* = undefined;
    }
};

/// All fields must still match when a prepared mesh becomes drawable. Merely
/// receiving its data or putting an upload on the queue does not install it.
pub const GeometryStamp = @import("engine").voxel_chunk.GeometryStamp;

pub const Request = union(enum) {
    definition: u64,
    snapshot: Identity,
    chunk: ChunkId,
};

fn snapshotOwnershipScenario(allocator: std.mem.Allocator) !void {
    var bits = [_]u8{1};
    var boxes = [_]ChunkId{2};
    var groups = [_]runtime.TargetGroup{.{ .chunk_id = 2, .first = 0, .count = 1, .transferred = true, .terrain_revision = 7 }};
    var indices = [_]u32{0};
    const source: runtime.Instance = .{
        .id = 1,
        .definition_id = 3,
        .owner = 4,
        .origin = .{ 64, 0, 0 },
        .rotation = 1,
        .fulfilled = &bits,
        .remaining = 0,
        .phase = .materializing,
        .revision = 2,
        .lifetime = 1,
        .box_chunks = &boxes,
        .target_groups = &groups,
        .target_indices = &indices,
        .cleanup_cursor = 37,
    };
    const borrowed = Snapshot.borrow(.{ .world_session = 9, .id = 1, .lifetime = 1 }, source);
    var owned = try borrowed.clone(allocator);
    defer owned.deinit(allocator);
    try std.testing.expect(!@hasField(Snapshot, "cleanup_cursor"));
    try std.testing.expect(owned.fulfilled.ptr != source.fulfilled.ptr);
    try std.testing.expect(owned.box_chunks.ptr != source.box_chunks.ptr);
    try std.testing.expect(owned.target_groups.ptr != source.target_groups.ptr);
    try std.testing.expect(owned.target_indices.ptr != source.target_indices.ptr);
    bits[0] = 0;
    groups[0].terrain_revision = 99;
    try std.testing.expectEqual(@as(u8, 1), owned.fulfilled[0]);
    try std.testing.expectEqual(@as(u64, 7), owned.target_groups[0].terrain_revision);
    var local = try owned.toInstance(allocator);
    defer local.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), local.cleanup_cursor);
    try std.testing.expectEqual(source.id, local.id);
    try std.testing.expectEqual(source.definition_id, local.definition_id);
    try std.testing.expectEqual(source.owner, local.owner);
    try std.testing.expectEqual(source.origin, local.origin);
    try std.testing.expectEqual(source.rotation, local.rotation);
    try std.testing.expectEqual(source.remaining, local.remaining);
    try std.testing.expectEqual(source.remaining_groups, local.remaining_groups);
    try std.testing.expectEqual(source.active, local.active);
    try std.testing.expectEqual(source.phase, local.phase);
    try std.testing.expectEqual(source.revision, local.revision);
    try std.testing.expectEqual(source.lifetime, local.lifetime);
    try std.testing.expectEqualSlices(ChunkId, owned.box_chunks, local.box_chunks);
    try std.testing.expectEqualDeep(owned.target_groups[0], local.target_groups[0]);
    try std.testing.expectEqualSlices(u32, owned.target_indices, local.target_indices);
    local.fulfilled[0] = 0;
    local.target_groups[0].terrain_revision = 8;
    try std.testing.expectEqual(@as(u8, 1), owned.fulfilled[0]);
    try std.testing.expectEqual(@as(u64, 7), owned.target_groups[0].terrain_revision);
    try std.testing.expectEqual(@as(usize, 37), source.cleanup_cursor);
}

test "construction snapshots own immutable arrays and isolate local cleanup across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotOwnershipScenario, .{});
}
