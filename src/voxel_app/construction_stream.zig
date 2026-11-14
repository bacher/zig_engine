//! Construction publication is independent of terrain representation. Snapshots
//! establish a revision; deltas are meaningful only against that exact revision.
const std = @import("std");
const runtime = @import("blueprint_runtime.zig");
pub const Identity = @import("construction_state.zig").Identity;
pub const Phase = runtime.Phase;
pub const ChunkId = @import("consts.zig").ChunkId;

pub const Snapshot = struct {
    identity: Identity,
    instance: runtime.Instance,

    pub fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        return .{ .identity = self.identity, .instance = try self.instance.clone(allocator) };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.instance.deinit(allocator);
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
