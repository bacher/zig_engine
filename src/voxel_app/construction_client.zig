//! Client-only revision/discovery and display reconciliation. Authoritative
//! progress remains in simulation; accepted cached contents live in World.
const std = @import("std");
const stream = @import("construction_stream.zig");
const runtime = @import("blueprint_runtime.zig");
const Identity = stream.Identity;
const ChunkId = stream.ChunkId;

pub const Limits = struct {
    sites: u32 = 4096,
    definitions: u32 = 4096,
    chunks: u32 = 8192,
    discovery_refs: usize = 65_536,
    requests: usize = 16_384,
};

pub const Decision = enum { apply, ignored, resync };

const Site = struct {
    identity: Identity,
    revision: u64 = 0,
    required_revision: u64 = 0,
    definition_id: u64 = 0,
    needs_snapshot: bool = true,
    retired: bool = false,
    retired_composition_revision: u64 = 0,
    references: usize = 0,
    evicting: bool = false,
};

const Chunk = struct {
    data: stream.GeometryStamp,
    composition: stream.ChunkComposition,
    installed: ?stream.GeometryStamp = null,
};

const Portion = struct { chunk_id: ChunkId, instance_id: u64, lifetime: u64 };
const TerrainPortion = struct { terrain_revision: u64, composition_revision: u64 };

pub const Cache = struct {
    world_session: u64 = 0,
    /// Physical-read availability and terrain ownership can change without a
    /// raw block or runtime progress revision changing.
    read_revision: u64 = 0,
    limits: Limits = .{},
    sites: std.AutoHashMapUnmanaged(u64, Site) = .empty,
    definitions: std.AutoHashMapUnmanaged(u64, void) = .empty,
    chunks: std.AutoHashMapUnmanaged(ChunkId, Chunk) = .empty,
    requests: std.ArrayList(stream.Request) = .empty,
    discovery_ref_count: usize = 0,
    static_portions: std.AutoHashMapUnmanaged(Portion, void) = .empty,
    terrain_portions: std.AutoHashMapUnmanaged(Portion, TerrainPortion) = .empty,

    pub fn invalidateReadView(self: *Cache) void {
        self.read_revision +%= 1;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| chunk.composition.deinit(allocator);
        self.chunks.deinit(allocator);
        self.sites.deinit(allocator);
        self.definitions.deinit(allocator);
        self.requests.deinit(allocator);
        self.static_portions.deinit(allocator);
        self.terrain_portions.deinit(allocator);
        self.* = .{};
    }

    /// A connection chooses its session once. A delayed package from another
    /// world cannot reset this cache or revive its registrations.
    pub fn acceptSession(self: *Cache, session: u64) bool {
        if (session == 0) return self.world_session == 0;
        if (self.world_session == 0) {
            self.world_session = session;
            self.invalidateReadView();
        }
        return self.world_session == session;
    }

    fn matchesSession(self: *const Cache, identity: Identity) bool {
        return identity.kind == .construction and identity.world_session == self.world_session and identity.id != 0 and identity.lifetime != 0;
    }

    fn enqueue(self: *Cache, allocator: std.mem.Allocator, request: stream.Request) !void {
        for (self.requests.items) |existing| if (std.meta.eql(existing, request)) return;
        if (self.requests.items.len >= self.limits.requests) return error.ConstructionCacheCapacity;
        try self.requests.append(allocator, request);
    }

    pub fn requestSnapshot(self: *Cache, allocator: std.mem.Allocator, identity: Identity) !void {
        if (!self.matchesSession(identity)) return;
        if (self.sites.getPtr(identity.id)) |known| {
            if (known.identity.lifetime > identity.lifetime) return;
            if (known.identity.lifetime < identity.lifetime) {
                known.* = .{ .identity = identity };
                self.invalidateReadView();
            }
        } else {
            if (self.sites.count() >= self.limits.sites) return error.ConstructionCacheCapacity;
            try self.sites.put(allocator, identity.id, .{ .identity = identity });
            self.invalidateReadView();
        }
        try self.enqueue(allocator, .{ .snapshot = identity });
    }

    pub fn invalidate(self: *Cache, allocator: std.mem.Allocator, identity: Identity) !void {
        if (self.sites.getPtr(identity.id)) |site| if (std.meta.eql(site.identity, identity)) {
            if (!site.needs_snapshot) self.invalidateReadView();
            site.needs_snapshot = true;
        };
        try self.requestSnapshot(allocator, identity);
    }

    pub fn requestChunk(self: *Cache, allocator: std.mem.Allocator, id: ChunkId) !void {
        try self.enqueue(allocator, .{ .chunk = id });
    }

    pub fn discover(self: *Cache, allocator: std.mem.Allocator, id: ChunkId, reference: stream.SiteRef) !void {
        const known = self.sites.get(reference.identity.id);
        if (known != null and std.meta.eql(known.?.identity, reference.identity) and known.?.retired) {
            try self.requestChunk(allocator, id);
        } else if (known == null or !std.meta.eql(known.?.identity, reference.identity) or known.?.needs_snapshot or known.?.revision < reference.site_revision) {
            try self.requestSnapshot(allocator, reference.identity);
        }
        if (self.sites.getPtr(reference.identity.id)) |site| if (std.meta.eql(site.identity, reference.identity)) {
            if (site.required_revision < reference.site_revision) self.invalidateReadView();
            site.required_revision = @max(site.required_revision, reference.site_revision);
        };
    }

    pub fn definitionInstalled(self: *Cache, allocator: std.mem.Allocator, id: u64) !void {
        if (!self.definitions.contains(id) and self.definitions.count() >= self.limits.definitions) return error.ConstructionCacheCapacity;
        const installed = try self.definitions.getOrPut(allocator, id);
        if (!installed.found_existing) self.invalidateReadView();
        var index: usize = 0;
        while (index < self.requests.items.len) {
            if (self.requests.items[index] == .definition and self.requests.items[index].definition == id) {
                _ = self.requests.orderedRemove(index);
            } else index += 1;
        }
    }

    fn ensureSite(self: *Cache, allocator: std.mem.Allocator, identity: Identity) !?*Site {
        _ = allocator;
        if (!self.matchesSession(identity)) return null;
        const known = self.sites.getPtr(identity.id) orelse return null;
        return if (std.meta.eql(known.identity, identity)) known else null;
    }

    pub fn checkSnapshot(self: *Cache, allocator: std.mem.Allocator, snapshot: stream.Snapshot) !Decision {
        const value = snapshot;
        if (snapshot.identity.id != value.id or snapshot.identity.lifetime != value.lifetime) return .ignored;
        const known = (try self.ensureSite(allocator, snapshot.identity)) orelse return .ignored;
        if (known.retired or known.evicting or value.revision < known.revision or (value.revision == known.revision and !known.needs_snapshot)) return .ignored;
        if (!self.definitions.contains(value.definition_id)) {
            try self.enqueue(allocator, .{ .definition = value.definition_id });
            try self.requestSnapshot(allocator, snapshot.identity);
            return .resync;
        }
        return .apply;
    }

    /// Called only after World has installed/rebased the compatible snapshot.
    pub fn snapshotInstalled(self: *Cache, snapshot: stream.Snapshot) void {
        const known = self.sites.getPtr(snapshot.identity.id).?;
        const required = known.required_revision;
        const references = known.references;
        known.* = .{ .identity = snapshot.identity, .revision = snapshot.revision, .required_revision = required, .definition_id = snapshot.definition_id, .needs_snapshot = false, .references = references };
        self.invalidateReadView();
        self.dropSatisfiedSnapshotRequests(known.*);
    }

    pub fn checkDelta(self: *Cache, allocator: std.mem.Allocator, delta: stream.Delta) !Decision {
        if (delta.revision <= delta.base_revision) return .ignored;
        const known = (try self.ensureSite(allocator, delta.identity)) orelse return .ignored;
        if (known.retired or known.evicting or delta.revision <= known.revision) return .ignored;
        if (known.needs_snapshot or delta.base_revision != known.revision) {
            if (!known.needs_snapshot) self.invalidateReadView();
            known.needs_snapshot = true;
            try self.requestSnapshot(allocator, delta.identity);
            return .resync;
        }
        return .apply;
    }

    pub fn deltaInstalled(self: *Cache, delta: stream.Delta) void {
        const known = self.sites.getPtr(delta.identity.id).?;
        std.debug.assert(std.meta.eql(known.identity, delta.identity));
        known.revision = delta.revision;
        self.invalidateReadView();
        self.dropSatisfiedSnapshotRequests(known.*);
    }

    fn dropSatisfiedSnapshotRequests(self: *Cache, site: Site) void {
        if (site.needs_snapshot or site.revision < site.required_revision) return;
        var index: usize = 0;
        while (index < self.requests.items.len) {
            const request = self.requests.items[index];
            if (request == .snapshot and std.meta.eql(request.snapshot, site.identity)) {
                _ = self.requests.orderedRemove(index);
            } else index += 1;
        }
    }

    pub fn retire(self: *Cache, allocator: std.mem.Allocator, value: stream.Retirement) !Decision {
        const known = (try self.ensureSite(allocator, value.identity)) orelse return .ignored;
        if (value.revision < known.revision or known.retired) return .ignored;
        // Stale discovery must be replaced with current terrain/object state.
        // Queue growth precedes the terminal mark so an allocation failure can
        // retry this same notice instead of ignoring its unfinished work.
        var chunks = self.chunks.iterator();
        while (chunks.next()) |entry| for (entry.value_ptr.composition.sites) |reference| {
            if (std.meta.eql(reference.identity, value.identity)) {
                try self.requestChunk(allocator, entry.key_ptr.*);
                break;
            }
        };
        known.revision = value.revision;
        known.retired = true;
        known.retired_composition_revision = value.composition_revision;
        known.needs_snapshot = false;
        self.invalidateReadView();
        return .apply;
    }

    /// The caller has already checked its currently selected subscription. This
    /// prepares a deep copy before replacing the old coherent discovery state.
    pub fn installChunk(self: *Cache, allocator: std.mem.Allocator, id: ChunkId, stamp: stream.GeometryStamp, composition: stream.ChunkComposition) !bool {
        if (stamp.composition_revision != composition.revision) return error.InvalidComposition;
        if (self.chunks.getPtr(id)) |old| {
            if (stamp.subscription_id < old.data.subscription_id) return false;
            if (stamp.subscription_id == old.data.subscription_id and
                (stamp.chunk_revision < old.data.chunk_revision or stamp.surface_revision < old.data.surface_revision or composition.revision < old.composition.revision)) return false;
        } else if (self.chunks.count() >= self.limits.chunks) return error.ConstructionCacheCapacity;
        const previous_refs = if (self.chunks.get(id)) |old| old.composition.sites.len else 0;
        if (composition.sites.len > self.limits.discovery_refs -| (self.discovery_ref_count - previous_refs)) return error.ConstructionCacheCapacity;
        for (composition.sites) |reference| if (!self.matchesSession(reference.identity)) return error.InvalidComposition;
        var new_references: std.AutoHashMapUnmanaged(Identity, stream.SiteRef) = .empty;
        defer new_references.deinit(allocator);
        try new_references.ensureTotalCapacity(allocator, @intCast(composition.sites.len));
        for (composition.sites) |reference| {
            const entry = new_references.getOrPutAssumeCapacity(reference.identity);
            if (entry.found_existing) return error.InvalidComposition;
            entry.value_ptr.* = reference;
        }
        const old_references = self.chunkReferences(id);
        if (self.chunks.get(id)) |old| if (old.composition.revision == composition.revision) {
            if (old_references.len != composition.sites.len) return error.InvalidComposition;
            for (old_references) |reference| {
                const current = new_references.get(reference.identity) orelse return error.InvalidComposition;
                if (reference.transferred != current.transferred or reference.terrain_revision != current.terrain_revision) return error.InvalidComposition;
            }
        };
        var new_portions: usize = 0;
        for (composition.sites) |reference| if (reference.transferred) {
            if (!self.terrain_portions.contains(.{ .chunk_id = id, .instance_id = reference.identity.id, .lifetime = reference.identity.lifetime })) new_portions += 1;
        };
        for (old_references) |reference| if (!new_references.contains(reference.identity)) {
            if (!self.terrain_portions.contains(.{ .chunk_id = id, .instance_id = reference.identity.id, .lifetime = reference.identity.lifetime })) new_portions += 1;
        };
        if (new_portions > self.limits.discovery_refs -| self.terrain_portions.count()) return error.ConstructionCacheCapacity;
        try self.terrain_portions.ensureUnusedCapacity(allocator, @intCast(new_portions));
        var copy = try composition.clone(allocator);
        errdefer copy.deinit(allocator);
        try self.chunks.ensureUnusedCapacity(allocator, 1);
        // Queue requests before committing discovery: failure keeps the old
        // availability state, so callers retry the complete terrain response.
        for (composition.sites) |reference| {
            try self.discover(allocator, id, reference);
        }
        // Removing a previously discovered reference in a newer coherent chunk
        // publication proves handback even if its separate lifecycle update is
        // delayed. An empty pre-admission snapshot provides no such evidence.
        for (old_references) |reference| if (!new_references.contains(reference.identity)) {
            self.recordTerrainPortion(id, reference.identity, stamp.chunk_revision, composition.revision);
        };
        for (composition.sites) |reference| if (reference.transferred) {
            self.recordTerrainPortion(id, reference.identity, reference.terrain_revision, composition.revision);
        };
        var installed: ?stream.GeometryStamp = null;
        if (self.chunks.getPtr(id)) |old| {
            installed = old.installed;
            for (old.composition.sites) |reference| if (self.sites.getPtr(reference.identity.id)) |site| {
                if (std.meta.eql(site.identity, reference.identity)) site.references -= 1;
            };
            old.composition.deinit(allocator);
        }
        for (copy.sites) |reference| if (self.sites.getPtr(reference.identity.id)) |site| {
            if (std.meta.eql(site.identity, reference.identity)) site.references += 1;
        };
        self.chunks.putAssumeCapacity(id, .{ .data = stamp, .composition = copy, .installed = installed });
        self.discovery_ref_count = self.discovery_ref_count - previous_refs + composition.sites.len;
        self.invalidateReadView();
        return true;
    }

    pub fn evictChunk(self: *Cache, allocator: std.mem.Allocator, id: ChunkId) void {
        self.invalidateReadView();
        if (self.chunks.fetchRemove(id)) |entry| {
            self.discovery_ref_count -= entry.value.composition.sites.len;
            for (entry.value.composition.sites) |reference| if (self.sites.getPtr(reference.identity.id)) |site| {
                if (std.meta.eql(site.identity, reference.identity)) site.references -= 1;
            };
            var composition = entry.value.composition;
            composition.deinit(allocator);
        }
        var portions = self.static_portions.keyIterator();
        while (portions.next()) |portion| {
            if (portion.chunk_id == id) _ = self.static_portions.remove(portion.*);
        }
        var terrain = self.terrain_portions.keyIterator();
        while (terrain.next()) |portion| {
            if (portion.chunk_id == id) _ = self.terrain_portions.remove(portion.*);
        }
    }

    /// Stop retaining an unobserved object after its runtime source is evicted.
    /// A delayed update has no interest record and cannot recreate the object;
    /// fresh discovery or an explicit resync must subscribe again first.
    pub fn forgetSite(self: *Cache, id: u64) bool {
        if (self.sites.get(id)) |site| if (site.references != 0) return false;
        self.invalidateReadView();
        _ = self.sites.remove(id);
        var portions = self.static_portions.keyIterator();
        while (portions.next()) |portion| {
            if (portion.instance_id == id) _ = self.static_portions.remove(portion.*);
        }
        var terrain = self.terrain_portions.keyIterator();
        while (terrain.next()) |portion| {
            if (portion.instance_id == id) _ = self.terrain_portions.remove(portion.*);
        }
        var index: usize = 0;
        while (index < self.requests.items.len) {
            if (self.requests.items[index] == .snapshot and self.requests.items[index].snapshot.id == id) {
                _ = self.requests.orderedRemove(index);
            } else index += 1;
        }
        return true;
    }

    pub fn beginEviction(self: *Cache, id: u64) void {
        if (self.sites.getPtr(id)) |site| {
            if (!site.evicting or !site.needs_snapshot) self.invalidateReadView();
            site.evicting = true;
            site.needs_snapshot = true;
        }
    }

    pub fn endEviction(self: *Cache, allocator: std.mem.Allocator, identity: Identity, needed: bool) !void {
        if (self.sites.getPtr(identity.id)) |site| {
            if (site.evicting) self.invalidateReadView();
            site.evicting = false;
        }
        if (needed) try self.requestSnapshot(allocator, identity) else _ = self.forgetSite(identity.id);
    }

    pub fn chunkAvailable(context: *const anyopaque, id: ChunkId) bool {
        const self: *const Cache = @ptrCast(@alignCast(context));
        const chunk = self.chunks.get(id) orelse return true;
        for (chunk.composition.sites) |reference| {
            const site = self.sites.get(reference.identity.id) orelse return false;
            if (!std.meta.eql(site.identity, reference.identity) or site.retired or site.evicting or !self.definitions.contains(site.definition_id)) return false;
            if (!reference.transferred and (site.needs_snapshot or site.revision < reference.site_revision)) return false;
            if (reference.transferred and chunk.data.chunk_revision < reference.terrain_revision) return false;
        }
        return true;
    }

    /// Called using the runtime's chunk directory, so this check does not scan
    /// global sites. It also covers completed sources whose old terrain snapshot
    /// predates discovery and therefore contains no reference to inspect above.
    pub fn instanceAvailable(self: *const Cache, id: ChunkId, instance: runtime.Instance) bool {
        const site = self.sites.get(instance.id) orelse return true;
        if (site.identity.lifetime != instance.lifetime or site.evicting) return false;
        if (site.needs_snapshot and terrainRevision(self, id, instance.id, instance.lifetime) == null) return false;
        const chunk = self.chunks.get(id) orelse return !site.retired and instance.phase != .complete;
        if (site.retired and chunk.composition.revision < site.retired_composition_revision) return false;
        if (instance.groupIndex(id)) |slot| {
            const group = instance.target_groups[slot];
            if (group.transferred and chunk.data.chunk_revision < group.terrain_revision) return false;
        }
        return true;
    }

    /// Only a successful installation of the still-current geometry can retire
    /// dynamic display. Retryable build/upload failure simply does not call this.
    pub fn geometryInstalled(self: *Cache, id: ChunkId, stamp: stream.GeometryStamp) bool {
        const chunk = self.chunks.getPtr(id) orelse return false;
        if (!std.meta.eql(chunk.data, stamp)) return false;
        chunk.installed = stamp;
        return true;
    }

    pub fn geometryStamp(self: *const Cache, id: ChunkId) ?stream.GeometryStamp {
        return if (self.chunks.get(id)) |chunk| chunk.data else null;
    }

    pub fn chunkReferences(self: *const Cache, id: ChunkId) []const stream.SiteRef {
        return if (self.chunks.get(id)) |chunk| chunk.composition.sites else &.{};
    }

    pub fn siteIdentity(self: *const Cache, id: u64) ?Identity {
        return if (self.sites.get(id)) |site| site.identity else null;
    }

    fn recordTerrainPortion(self: *Cache, id: ChunkId, identity: Identity, terrain_revision: u64, composition_revision: u64) void {
        const entry = self.terrain_portions.getOrPutAssumeCapacity(.{ .chunk_id = id, .instance_id = identity.id, .lifetime = identity.lifetime });
        if (!entry.found_existing) entry.value_ptr.* = .{ .terrain_revision = terrain_revision, .composition_revision = composition_revision } else {
            entry.value_ptr.terrain_revision = @max(entry.value_ptr.terrain_revision, terrain_revision);
            entry.value_ptr.composition_revision = @max(entry.value_ptr.composition_revision, composition_revision);
        }
    }

    pub fn terrainRevision(context: *const anyopaque, id: ChunkId, instance_id: u64, lifetime: u64) ?u64 {
        const self: *const Cache = @ptrCast(@alignCast(context));
        const chunk = self.chunks.get(id) orelse return null;
        if (self.terrain_portions.get(.{ .chunk_id = id, .instance_id = instance_id, .lifetime = lifetime })) |portion| {
            if (chunk.composition.revision >= portion.composition_revision) return portion.terrain_revision;
        }
        const site = self.sites.get(instance_id) orelse return null;
        if (site.identity.lifetime == lifetime and site.retired and site.retired_composition_revision != 0 and chunk.composition.revision >= site.retired_composition_revision) return chunk.data.chunk_revision;
        return null;
    }

    pub fn hasStaticSelection(self: *const Cache, id: ChunkId, instance: runtime.Instance) bool {
        return self.static_portions.contains(.{ .chunk_id = id, .instance_id = instance.id, .lifetime = instance.lifetime });
    }

    /// Reserve before preparing the upload batch that may remove dynamic data.
    /// Selecting the installed replacement afterward is allocation-free.
    pub fn reserveStaticSelections(self: *Cache, allocator: std.mem.Allocator, additional: usize) !void {
        if (additional > self.limits.discovery_refs -| self.static_portions.count()) return error.ConstructionCacheCapacity;
        try self.static_portions.ensureUnusedCapacity(allocator, @intCast(additional));
    }

    pub fn selectStaticAssumeCapacity(self: *Cache, id: ChunkId, instance: runtime.Instance) void {
        self.static_portions.putAssumeCapacity(.{ .chunk_id = id, .instance_id = instance.id, .lifetime = instance.lifetime }, {});
    }

    /// Membership and data ownership can retire earlier than the visible source.
    /// A newer post-completion surface also qualifies; its stamp has been checked at
    /// installation and cannot be replaced by an older queued job.
    pub fn portionReady(self: *const Cache, id: ChunkId, instance: runtime.Instance, terrain_revision: u64) bool {
        if (self.hasStaticSelection(id, instance)) return true;
        const chunk = self.chunks.get(id) orelse return false;
        const installed = chunk.installed orelse return false;
        return self.portionReadyForGeometry(id, instance, terrain_revision, installed);
    }

    /// Used to prepare both layers of one atomic upload batch. The caller must
    /// queue this exact terrain stamp together with the dynamic replacement.
    pub fn portionReadyForGeometry(self: *const Cache, id: ChunkId, instance: runtime.Instance, terrain_revision: u64, installed: stream.GeometryStamp) bool {
        const chunk = self.chunks.get(id) orelse return false;
        if (!std.meta.eql(installed, chunk.data)) return false;
        if (self.sites.get(instance.id)) |site| if (site.retired and chunk.composition.revision < site.retired_composition_revision) return false;
        if (installed.subscription_id != chunk.data.subscription_id or installed.chunk_revision < terrain_revision) return false;
        if (installed.composition_revision > chunk.composition.revision) return false;
        for (chunk.composition.sites) |reference| {
            if (reference.identity.id != instance.id or reference.identity.lifetime != instance.lifetime) continue;
            return reference.transferred and installed.composition_revision >= chunk.composition.revision and installed.chunk_revision >= reference.terrain_revision;
        }
        // A coherent newer snapshot has already retired this site's discovery.
        const group_index = instance.groupIndex(id) orelse return false;
        const ownership = terrainRevision(self, id, instance.id, instance.lifetime);
        return (instance.phase == .complete or instance.target_groups[group_index].transferred or ownership != null) and
            installed.composition_revision == chunk.composition.revision and (ownership == null or installed.chunk_revision >= ownership.?);
    }
};

fn testIdentity(id: u64) Identity {
    return .{ .world_session = 91, .id = id, .lifetime = id };
}

fn testSnapshot(id: u64, revision: u64) stream.Snapshot {
    return .{
        .identity = testIdentity(id),
        .id = id,
        .lifetime = id,
        .definition_id = 7,
        .owner = 1,
        .origin = .{ 31, 10, 10 },
        .rotation = 1,
        .fulfilled = &.{},
        .remaining = 0,
        .box_chunks = &.{},
        .revision = revision,
    };
}

test "construction snapshots share definitions and delta gaps require a snapshot" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    try std.testing.expect(cache.acceptSession(91));
    try std.testing.expect(!cache.acceptSession(92));
    const first = testSnapshot(1, 10);
    try cache.requestSnapshot(allocator, first.identity);
    try std.testing.expectEqual(Decision.resync, try cache.checkSnapshot(allocator, first));
    try std.testing.expectEqual(@as(usize, 2), cache.requests.items.len);
    try cache.definitionInstalled(allocator, 7);
    try std.testing.expectEqual(Decision.apply, try cache.checkSnapshot(allocator, first));
    cache.snapshotInstalled(first);
    const second = testSnapshot(2, 10);
    try cache.requestSnapshot(allocator, second.identity);
    try std.testing.expectEqual(Decision.apply, try cache.checkSnapshot(allocator, second));
    cache.snapshotInstalled(second);
    try std.testing.expectEqual(@as(u32, 1), cache.definitions.count());
    try std.testing.expectEqual(@as(usize, 0), cache.requests.items.len);

    const next: stream.Delta = .{ .identity = first.identity, .base_revision = 10, .revision = 14, .fulfilled_indices = &.{ 1, 5, 9, 12 } };
    try std.testing.expectEqual(Decision.apply, try cache.checkDelta(allocator, next));
    cache.deltaInstalled(next);
    try std.testing.expectEqual(Decision.ignored, try cache.checkDelta(allocator, next));
    const gap: stream.Delta = .{ .identity = first.identity, .base_revision = 16, .revision = 17, .fulfilled_indices = &.{18} };
    try std.testing.expectEqual(Decision.resync, try cache.checkDelta(allocator, gap));
    const late: stream.Delta = .{ .identity = first.identity, .base_revision = 14, .revision = 16, .fulfilled_indices = &.{ 14, 16 } };
    try std.testing.expectEqual(Decision.resync, try cache.checkDelta(allocator, late));
    try std.testing.expectEqual(@as(u64, 14), cache.sites.get(1).?.revision);
    const current = testSnapshot(1, 17);
    try std.testing.expectEqual(Decision.apply, try cache.checkSnapshot(allocator, current));
    cache.snapshotInstalled(current);
    try std.testing.expectEqual(Decision.ignored, try cache.checkSnapshot(allocator, first));
    var wrong_kind = next;
    wrong_kind.identity.kind = .warehouse;
    wrong_kind.base_revision = 17;
    wrong_kind.revision = 18;
    try std.testing.expectEqual(Decision.ignored, try cache.checkDelta(allocator, wrong_kind));
    var wrong_session = wrong_kind;
    wrong_session.identity.kind = .construction;
    wrong_session.identity.world_session += 1;
    try std.testing.expectEqual(Decision.ignored, try cache.checkDelta(allocator, wrong_session));
}

test "discovery is unknown until its definition and compatible construction arrive" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    const references = [_]stream.SiteRef{
        .{ .identity = testIdentity(1), .site_revision = 5 },
        .{ .identity = testIdentity(2), .site_revision = 8 },
    };
    const stamp: stream.GeometryStamp = .{ .subscription_id = 11, .chunk_revision = 3, .surface_revision = 5, .composition_revision = 2 };
    try std.testing.expect(try cache.installChunk(allocator, 6, stamp, .{ .revision = 2, .sites = &references }));
    try std.testing.expect(!Cache.chunkAvailable(&cache, 6));
    try cache.definitionInstalled(allocator, 7);
    const first = testSnapshot(1, 5);
    _ = try cache.checkSnapshot(allocator, first);
    cache.snapshotInstalled(first);
    try std.testing.expect(!Cache.chunkAvailable(&cache, 6));
    const second = testSnapshot(2, 8);
    _ = try cache.checkSnapshot(allocator, second);
    cache.snapshotInstalled(second);
    try std.testing.expect(Cache.chunkAvailable(&cache, 6));
    const gap: stream.Delta = .{ .identity = testIdentity(2), .base_revision = 9, .revision = 10 };
    _ = try cache.checkDelta(allocator, gap);
    try std.testing.expect(!Cache.chunkAvailable(&cache, 6));
    const recovered = testSnapshot(2, 10);
    _ = try cache.checkSnapshot(allocator, recovered);
    cache.snapshotInstalled(recovered);
    try std.testing.expect(Cache.chunkAvailable(&cache, 6));
    _ = try cache.retire(allocator, .{ .identity = testIdentity(1), .revision = 20 });
    try std.testing.expect(!Cache.chunkAvailable(&cache, 6));
    try std.testing.expectEqual(Decision.ignored, try cache.checkSnapshot(allocator, testSnapshot(1, 30)));
    var newer_stamp = stamp;
    newer_stamp.composition_revision = 3;
    try std.testing.expect(try cache.installChunk(allocator, 6, newer_stamp, .{ .revision = 3, .sites = references[1..] }));
    try std.testing.expect(Cache.chunkAvailable(&cache, 6));
}

test "terrain readiness does not retire display before matching geometry installs" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    try cache.definitionInstalled(allocator, 7);
    var snapshot = testSnapshot(1, 9);
    var groups = [_]runtime.TargetGroup{.{ .chunk_id = 2, .first = 0, .count = 1, .transferred = true, .terrain_revision = 12 }};
    snapshot.target_groups = &groups;
    try cache.requestSnapshot(allocator, snapshot.identity);
    _ = try cache.checkSnapshot(allocator, snapshot);
    cache.snapshotInstalled(snapshot);
    var instance = try snapshot.toInstance(allocator);
    defer instance.deinit(allocator);
    const reference: stream.SiteRef = .{ .identity = snapshot.identity, .site_revision = 9, .transferred = true, .terrain_revision = 12 };
    const stamp: stream.GeometryStamp = .{ .subscription_id = 3, .chunk_revision = 12, .surface_revision = 30, .composition_revision = 4 };
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 4, .sites = &.{reference} }));
    try std.testing.expect(Cache.chunkAvailable(&cache, 2));
    try std.testing.expect(!cache.portionReady(2, instance, 12));
    var stale = stamp;
    stale.surface_revision -= 1;
    try std.testing.expect(!cache.geometryInstalled(2, stale));
    try std.testing.expect(!cache.portionReady(2, instance, 12));
    // Failed/retried builds leave the same selected source. Static metadata may
    // precede a separate lifecycle update; only successful install switches it.
    try std.testing.expect(cache.geometryInstalled(2, stamp));
    try std.testing.expect(cache.portionReady(2, instance, 12));
    var rebuilt_surface = stamp;
    rebuilt_surface.surface_revision += 1;
    try std.testing.expect(try cache.installChunk(allocator, 2, rebuilt_surface, .{ .revision = 4, .sites = &.{reference} }));
    try std.testing.expect(!cache.portionReady(2, instance, 12));
    try std.testing.expect(cache.geometryInstalled(2, rebuilt_surface));
    try std.testing.expect(cache.portionReady(2, instance, 12));
    var edited = stamp;
    edited.chunk_revision += 1;
    edited.surface_revision += 1;
    edited.composition_revision += 1;
    try std.testing.expect(try cache.installChunk(allocator, 2, edited, .{ .revision = 5 }));
    try std.testing.expect(!cache.geometryInstalled(2, stamp));
    try std.testing.expect(!cache.portionReady(2, instance, 12));
    try std.testing.expect(cache.geometryInstalled(2, edited));
    try std.testing.expect(cache.portionReady(2, instance, 12));
    try std.testing.expect(!try cache.installChunk(allocator, 2, stamp, .{ .revision = 4, .sites = &.{reference} }));
    var reloaded = edited;
    reloaded.subscription_id += 1;
    try std.testing.expect(try cache.installChunk(allocator, 2, reloaded, .{ .revision = 5 }));
    try std.testing.expect(!cache.geometryInstalled(2, edited));
    try std.testing.expect(!cache.portionReady(2, instance, 12));
    cache.evictChunk(allocator, 2);
    try std.testing.expect(!cache.geometryInstalled(2, reloaded));
}

fn exerciseChunkAllocation(allocator: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    const stamp: stream.GeometryStamp = .{ .subscription_id = 1, .composition_revision = 1 };
    try std.testing.expect(try cache.installChunk(allocator, 3, stamp, .{ .revision = 1, .sites = &.{.{ .identity = testIdentity(1), .site_revision = 3 }} }));
    var next = stamp;
    next.composition_revision = 2;
    try std.testing.expect(try cache.installChunk(allocator, 3, next, .{ .revision = 2 }));
    try std.testing.expectEqual(@as(usize, 0), cache.discovery_ref_count);
}

test "construction discovery cleans up allocation failures and bounds retained references" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseChunkAllocation, .{});
    const allocator = std.testing.allocator;
    var cache: Cache = .{ .limits = .{ .discovery_refs = 1 } };
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    const reference: stream.SiteRef = .{ .identity = testIdentity(1), .site_revision = 3 };
    const stamp: stream.GeometryStamp = .{ .subscription_id = 1, .composition_revision = 1 };
    try std.testing.expect(try cache.installChunk(allocator, 3, stamp, .{ .revision = 1, .sites = &.{reference} }));
    var next = stamp;
    next.composition_revision += 1;
    try std.testing.expectError(error.ConstructionCacheCapacity, cache.installChunk(allocator, 3, next, .{ .revision = 2, .sites = &.{ reference, reference } }));
    try std.testing.expectEqual(@as(u64, 1), cache.chunks.get(3).?.composition.revision);
    try std.testing.expectEqual(@as(usize, 1), cache.discovery_ref_count);
}

test "construction terrain ownership can precede lifecycle progress and survives reference removal" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    try cache.definitionInstalled(allocator, 7);
    var snapshot = testSnapshot(1, 2);
    var groups = [_]runtime.TargetGroup{.{ .chunk_id = 2, .first = 0, .count = 1 }};
    snapshot.target_groups = &groups;
    try cache.requestSnapshot(allocator, snapshot.identity);
    cache.snapshotInstalled(snapshot);
    var instance = try snapshot.toInstance(allocator);
    defer instance.deinit(allocator);
    var stamp: stream.GeometryStamp = .{ .subscription_id = 1, .chunk_revision = 0, .surface_revision = 1, .composition_revision = 1 };
    // Empty metadata received before admission cannot hand ownership to terrain.
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 1 }));
    try std.testing.expectEqual(null, Cache.terrainRevision(&cache, 2, 1, 1));
    stamp.composition_revision = 2;
    const pending: stream.SiteRef = .{ .identity = snapshot.identity, .site_revision = 2 };
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 2, .sites = &.{pending} }));
    try std.testing.expectEqual(null, Cache.terrainRevision(&cache, 2, 1, 1));
    stamp.chunk_revision = 12;
    stamp.surface_revision = 13;
    stamp.composition_revision = 3;
    const transferred: stream.SiteRef = .{ .identity = snapshot.identity, .site_revision = 20, .transferred = true, .terrain_revision = 12 };
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 3, .sites = &.{transferred} }));
    try std.testing.expectEqual(@as(?u64, 12), Cache.terrainRevision(&cache, 2, 1, 1));
    try std.testing.expect(Cache.chunkAvailable(&cache, 2));
    try std.testing.expect(cache.instanceAvailable(2, instance));
    try std.testing.expect(!cache.portionReady(2, instance, 0));
    // A lost progress chain does not override coherent transferred terrain.
    _ = try cache.checkDelta(allocator, .{ .identity = snapshot.identity, .base_revision = 19, .revision = 20 });
    try std.testing.expect(Cache.chunkAvailable(&cache, 2));
    try std.testing.expect(cache.instanceAvailable(2, instance));
    stamp.chunk_revision = 14;
    stamp.surface_revision = 15;
    stamp.composition_revision = 4;
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 4 }));
    try std.testing.expectEqual(@as(?u64, 14), Cache.terrainRevision(&cache, 2, 1, 1));
    try std.testing.expect(cache.instanceAvailable(2, instance));
    try std.testing.expect(cache.geometryInstalled(2, stamp));
    try std.testing.expect(cache.portionReady(2, instance, 0));
    try cache.reserveStaticSelections(allocator, 1);
    cache.selectStaticAssumeCapacity(2, instance);
    stamp.chunk_revision += 1;
    stamp.surface_revision += 1;
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 4 }));
    // A newer ordinary edit never revives old construction geometry.
    try std.testing.expect(cache.portionReady(2, instance, 0));
}

test "construction retirement after a gap requires its composition watermark" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    try cache.definitionInstalled(allocator, 7);
    var snapshot = testSnapshot(1, 2);
    var groups = [_]runtime.TargetGroup{.{ .chunk_id = 2, .first = 0, .count = 1 }};
    snapshot.target_groups = &groups;
    snapshot.phase = .complete;
    try cache.requestSnapshot(allocator, snapshot.identity);
    cache.snapshotInstalled(snapshot);
    var instance = try snapshot.toInstance(allocator);
    defer instance.deinit(allocator);
    var stamp: stream.GeometryStamp = .{ .subscription_id = 1, .chunk_revision = 0, .surface_revision = 1, .composition_revision = 1 };
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 1 }));
    _ = try cache.checkDelta(allocator, .{ .identity = snapshot.identity, .base_revision = 19, .revision = 20 });
    _ = try cache.retire(allocator, .{ .identity = snapshot.identity, .revision = 21, .composition_revision = 5 });
    try std.testing.expect(!cache.instanceAvailable(2, instance));
    try std.testing.expectEqual(null, Cache.terrainRevision(&cache, 2, 1, 1));
    try std.testing.expect(cache.geometryInstalled(2, stamp));
    try std.testing.expect(!cache.portionReady(2, instance, 0));
    stamp.chunk_revision = 12;
    stamp.surface_revision = 13;
    stamp.composition_revision = 5;
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 5 }));
    try std.testing.expect(cache.instanceAvailable(2, instance));
    try std.testing.expectEqual(@as(?u64, 12), Cache.terrainRevision(&cache, 2, 1, 1));
    try std.testing.expect(!cache.portionReady(2, instance, 0));
    try std.testing.expect(cache.geometryInstalled(2, stamp));
    try std.testing.expect(cache.portionReady(2, instance, 0));
}

test "construction eviction rejects delayed updates and fresh discovery subscribes again" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    try cache.definitionInstalled(allocator, 7);
    const snapshot = testSnapshot(1, 2);
    try cache.requestSnapshot(allocator, snapshot.identity);
    cache.snapshotInstalled(snapshot);
    var instance = try snapshot.toInstance(allocator);
    defer instance.deinit(allocator);
    const stamp: stream.GeometryStamp = .{ .subscription_id = 1, .chunk_revision = 12, .surface_revision = 13, .composition_revision = 1 };
    const reference: stream.SiteRef = .{ .identity = snapshot.identity, .site_revision = 2, .transferred = true, .terrain_revision = 12 };
    try std.testing.expect(try cache.installChunk(allocator, 2, stamp, .{ .revision = 1, .sites = &.{reference} }));
    cache.beginEviction(1);
    try std.testing.expect(!Cache.chunkAvailable(&cache, 2));
    try std.testing.expect(!cache.instanceAvailable(2, instance));
    try std.testing.expectEqual(Decision.ignored, try cache.checkSnapshot(allocator, testSnapshot(1, 3)));
    cache.evictChunk(allocator, 2);
    try cache.endEviction(allocator, snapshot.identity, false);
    try std.testing.expectEqual(Decision.ignored, try cache.checkSnapshot(allocator, testSnapshot(1, 4)));
    try std.testing.expectEqual(Decision.ignored, try cache.checkDelta(allocator, .{ .identity = snapshot.identity, .base_revision = 4, .revision = 5 }));
    try cache.discover(allocator, 2, reference);
    try std.testing.expectEqual(Decision.apply, try cache.checkSnapshot(allocator, testSnapshot(1, 5)));
}

fn exerciseRetirementAllocation(allocator: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    const reference: stream.SiteRef = .{ .identity = testIdentity(1), .site_revision = 2 };
    const stamp: stream.GeometryStamp = .{ .subscription_id = 1, .composition_revision = 1 };
    for (0..10) |id| _ = try cache.installChunk(allocator, @intCast(id), stamp, .{ .revision = 1, .sites = &.{reference} });
    cache.requests.clearAndFree(allocator);
    _ = cache.retire(allocator, .{ .identity = reference.identity, .revision = 3, .composition_revision = 2 }) catch |err| {
        try std.testing.expect(!cache.sites.get(1).?.retired);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 10), cache.requests.items.len);
    try std.testing.expect(cache.sites.get(1).?.retired);
}

test "construction retirement allocation failures preserve a retryable source" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseRetirementAllocation, .{});
}

test "construction snapshot payload benchmark" {
    if (@import("builtin").mode != .ReleaseFast) return error.SkipZigTest;
    try @import("construction_snapshot_benchmark.zig").run();
}
