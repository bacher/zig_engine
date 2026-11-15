//! Simulation-owned warehouse aggregates. The service executor owns mutation;
//! terrain, player inventory, and publication commit around these local APIs.
const std = @import("std");
pub const layout = @import("warehouse_layout.zig");
pub const claims_module = @import("warehouse_claims.zig");
pub const deliveries = @import("warehouse_deliveries.zig");
pub const Identity = @import("construction_state.zig").Identity;
pub const BlockType = @import("engine").voxel_chunk.BlockType;
pub const Cell = layout.Cell;
pub const Geometry = layout.Geometry;
pub const Transition = deliveries.Transition;
pub const Error = error{ InvalidIdentity, InvalidMaterial, InvalidQuantity, InvalidStock, InvalidActiveCount, CapacityExceeded, EmptyStock, Stopped, Busy, NotStopped, MissingWarehouse, ConflictingClaim, IdentityExhausted, RevisionExhausted, SameWarehouse, InvalidObligations } || layout.Error || deliveries.Error || std.mem.Allocator.Error;

pub const Record = struct {
    identity: Identity,
    geometry: Geometry,
    material: BlockType,
    stock: u16 = 0,
    incoming: u16 = 0,
    active: u8,
    enabled: bool = true,
    obligations: u32 = 0,
    revision: u64 = 0,

    pub fn init(identity: Identity, geometry: Geometry, material: BlockType) Error!Record {
        try geometry.bounds.validate();
        const result: Record = .{ .identity = identity, .geometry = geometry, .material = material, .active = geometry.bounds.count() };
        try result.validate();
        return result;
    }

    pub fn validate(self: Record) Error!void {
        if (self.identity.kind != .warehouse or self.identity.id == 0 or self.identity.lifetime == 0) return error.InvalidIdentity;
        try self.geometry.bounds.validate();
        if (!self.material.canStoreInWarehouse()) return error.InvalidMaterial;
        if (self.active > self.geometry.bounds.count()) return error.InvalidActiveCount;
        if (@as(u32, self.stock) + self.incoming > self.physicalCapacity()) return error.InvalidStock;
    }

    pub fn physicalCapacity(self: Record) u16 {
        return @as(u16, self.geometry.bounds.count()) * layout.levels;
    }

    pub fn activeCapacity(self: Record) u16 {
        return @as(u16, self.active) * layout.levels;
    }

    pub fn demand(self: Record) u16 {
        return @as(u16, self.active) * 4 -| (self.stock + self.incoming);
    }

    pub fn admissionRoom(self: Record) u16 {
        return self.activeCapacity() -| (self.stock + self.incoming);
    }

    pub fn canAdd(self: Record, quantity: u16) bool {
        return quantity > 0 and quantity <= self.admissionRoom();
    }

    pub fn canManage(self: Record) bool {
        return !self.enabled and self.stock == 0 and self.incoming == 0 and self.obligations == 0;
    }

    pub fn ensureRevision(self: Record) Error!void {
        if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
    }

    pub fn put(self: *Record, material: BlockType, quantity: u16) Error!void {
        if (material != self.material or !material.canStoreInWarehouse()) return error.InvalidMaterial;
        if (quantity == 0) return error.InvalidQuantity;
        if (!self.canAdd(quantity)) return error.CapacityExceeded;
        try self.ensureRevision();
        self.stock += quantity;
        self.revision += 1;
    }

    pub fn take(self: *Record, quantity: u16) Error!BlockType {
        if (quantity == 0) return error.InvalidQuantity;
        if (quantity > self.stock) return error.EmptyStock;
        try self.ensureRevision();
        self.stock -= quantity;
        self.revision += 1;
        return self.material;
    }

    pub fn setActive(self: *Record, active: u8) Error!bool {
        if (active > self.geometry.bounds.count()) return error.InvalidActiveCount;
        if (self.active == active) return false;
        try self.ensureRevision();
        self.active = active;
        self.revision += 1;
        return true;
    }

    pub fn setEnabled(self: *Record, enabled: bool) Error!bool {
        if (self.enabled == enabled) return false;
        try self.ensureRevision();
        self.enabled = enabled;
        self.revision += 1;
        return true;
    }

    pub fn changeMaterial(self: *Record, material: BlockType) Error!bool {
        if (!material.canStoreInWarehouse()) return error.InvalidMaterial;
        if (!self.canManage()) return if (self.enabled) error.NotStopped else error.Busy;
        if (self.material == material) return false;
        try self.ensureRevision();
        self.material = material;
        self.revision += 1;
        return true;
    }

    pub fn occupied(self: Record, derived: layout.Layout, world_width: u32, cell: Cell) bool {
        const relative = self.geometry.relativeCell(world_width, cell) orelse return false;
        return derived.occupied(self.stock, self.active, relative);
    }
};

pub const State = struct {
    records: std.AutoHashMapUnmanaged(u64, Record) = .empty,
    /// Disposable permutations; never serialized or independently writable stock.
    layouts: std.AutoHashMapUnmanaged(u64, layout.Layout) = .empty,
    claims: claims_module.Index = .{},
    delivery_state: deliveries.Store = .{},
    world_session: u64 = 0,
    world_size: Cell = .{ 0, 0, 0 },
    next_id: u64 = 1,
    revision: u64 = 0,
    record_limit: usize = 4096,

    pub fn init(world_session: u64, world_size: Cell) State {
        return .{ .world_session = world_session, .world_size = world_size };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.layouts.deinit(allocator);
        self.claims.deinit(allocator);
        self.delivery_state.deinit(allocator);
        self.* = .{};
    }

    pub fn clone(self: State, allocator: std.mem.Allocator) !State {
        var result = self;
        result.claims = .{};
        result.layouts = .empty;
        result.records = try self.records.clone(allocator);
        errdefer result.records.deinit(allocator);
        result.delivery_state = try self.delivery_state.clone(allocator);
        errdefer result.delivery_state.deinit(allocator);
        try result.rebuildClaims(allocator);
        return result;
    }

    pub fn estimatedOwnedBytes(self: State) usize {
        return self.records.capacity() * (@sizeOf(u64) + @sizeOf(Record) + 1) +
            self.delivery_state.records.capacity() * (@sizeOf(u64) + @sizeOf(deliveries.Delivery) + 1) +
            self.layouts.capacity() * (@sizeOf(u64) + @sizeOf(layout.Layout) + 1) + self.claims.estimatedOwnedBytes();
    }

    pub fn ensureRevision(self: *const State) Error!void {
        if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
    }

    /// Call only after ensureRevision succeeds and the complete resource/record
    /// mutation is ready to commit. There are no fallible operations afterward.
    pub fn commitChanged(self: *State) void {
        std.debug.assert(self.revision != std.math.maxInt(u64));
        self.revision += 1;
    }

    pub fn touch(self: *State) Error!void {
        try self.ensureRevision();
        self.commitChanged();
    }

    pub fn get(self: *const State, identity: Identity) ?Record {
        const record = self.records.get(identity.id) orelse return null;
        return if (record.identity.eql(identity)) record else null;
    }

    pub fn getPtr(self: *State, identity: Identity) ?*Record {
        const record = self.records.getPtr(identity.id) orelse return null;
        return if (record.identity.eql(identity)) record else null;
    }

    pub fn layoutFor(self: *const State, identity: Identity) ?*const layout.Layout {
        _ = self.get(identity) orelse return null;
        return self.layouts.getPtr(identity.id);
    }

    pub fn occupied(self: *const State, identity: Identity, cell: Cell) bool {
        const record = self.get(identity) orelse return false;
        return record.occupied((self.layoutFor(identity) orelse return false).*, self.world_size[0], cell);
    }

    /// Terrain members, support, reach and blueprint-target checks must already
    /// be established by the service in the same serialized confirmation.
    pub fn register(self: *State, allocator: std.mem.Allocator, geometry: Geometry, material: BlockType) Error!Record {
        try geometry.validate(self.world_size);
        try self.ensureRevision();
        if (self.records.count() >= self.record_limit) return error.Busy;
        if (self.next_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (!try self.claims.canInsert(self.world_size, geometry)) return error.ConflictingClaim;
        const identity: Identity = .{ .world_session = self.world_session, .kind = .warehouse, .id = self.next_id, .lifetime = self.next_id };
        const record = try Record.init(identity, geometry, material);
        try self.records.ensureUnusedCapacity(allocator, 1);
        try self.layouts.ensureUnusedCapacity(allocator, 1);
        self.claims.insert(allocator, self.world_size, .{ .identity = identity, .geometry = geometry }) catch |err| switch (err) {
            error.DuplicateRegistration => return error.InvalidIdentity,
            else => |failure| return failure,
        };
        self.records.putAssumeCapacityNoClobber(identity.id, record);
        self.layouts.putAssumeCapacityNoClobber(identity.id, layout.Layout.init(geometry));
        self.next_id += 1;
        self.commitChanged();
        return record;
    }

    pub fn unregister(self: *State, allocator: std.mem.Allocator, identity: Identity) Error!Record {
        const record = self.get(identity) orelse return error.MissingWarehouse;
        if (!record.canManage()) return if (record.enabled) error.NotStopped else error.Busy;
        try self.ensureRevision();
        self.claims.remove(allocator, self.world_size, .{ .identity = identity, .geometry = record.geometry });
        _ = self.records.remove(identity.id);
        _ = self.layouts.remove(identity.id);
        self.commitChanged();
        return record;
    }

    pub fn rebuildClaims(self: *State, allocator: std.mem.Allocator) Error!void {
        var rebuilt: claims_module.Index = .{};
        errdefer rebuilt.deinit(allocator);
        var rebuilt_layouts: std.AutoHashMapUnmanaged(u64, layout.Layout) = .empty;
        errdefer rebuilt_layouts.deinit(allocator);
        try rebuilt_layouts.ensureTotalCapacity(allocator, self.records.count());
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record| {
            try record.validate();
            try record.geometry.validate(self.world_size);
            if (!try rebuilt.canInsert(self.world_size, record.geometry)) return error.ConflictingClaim;
            rebuilt.insert(allocator, self.world_size, .{ .identity = record.identity, .geometry = record.geometry }) catch |err| switch (err) {
                error.DuplicateRegistration => return error.InvalidIdentity,
                else => |failure| return failure,
            };
            rebuilt_layouts.putAssumeCapacityNoClobber(record.identity.id, layout.Layout.init(record.geometry));
        }
        self.claims.deinit(allocator);
        self.claims = rebuilt;
        self.layouts.deinit(allocator);
        self.layouts = rebuilt_layouts;
    }

    /// No routing, cost, worker allocation, or clock is introduced here. The
    /// caller establishes those prerequisites; this transition owns real stock,
    /// delivery cargo, a matching destination promise, and both obligations.
    pub fn startDelivery(self: *State, allocator: std.mem.Allocator, id: u64, source_id: Identity, destination_id: Identity, material: BlockType, quantity: u16) Error!Transition {
        const intent: deliveries.Intent = .{ .source = source_id, .destination = destination_id, .material = material, .quantity = quantity };
        if (try self.delivery_state.existing(id, intent)) |_| return .replayed;
        try self.ensureRevision();
        if (source_id.eql(destination_id)) return error.SameWarehouse;
        const source = self.getPtr(source_id) orelse return error.MissingWarehouse;
        const destination = self.getPtr(destination_id) orelse return error.MissingWarehouse;
        if (!source.enabled or !destination.enabled) return error.Stopped;
        if (material != source.material or material != destination.material or !material.canStoreInWarehouse()) return error.InvalidMaterial;
        if (quantity == 0) return error.InvalidQuantity;
        if (source.stock < quantity) return error.EmptyStock;
        if (!destination.canAdd(quantity)) return error.CapacityExceeded;
        if (source.obligations == std.math.maxInt(u32) or destination.obligations == std.math.maxInt(u32)) return error.Busy;
        try source.ensureRevision();
        try destination.ensureRevision();
        try self.delivery_state.prepare(allocator);
        // All failure points precede the coherent transition.
        source.stock -= quantity;
        destination.incoming += quantity;
        source.obligations += 1;
        destination.obligations += 1;
        source.revision += 1;
        destination.revision += 1;
        self.delivery_state.install(.{ .id = id, .intent = intent, .cargo = quantity, .remaining_promise = quantity });
        self.commitChanged();
        return .applied;
    }

    pub fn handover(self: *State, id: u64) Error!Transition {
        if (id == 0) return error.InvalidDeliveryId;
        if (id <= self.delivery_state.completed_through) return .replayed;
        const delivery = self.delivery_state.records.getPtr(id) orelse return error.MissingDelivery;
        if (delivery.complete) return .replayed;
        try self.ensureRevision();
        const source = self.getPtr(delivery.intent.source) orelse return error.MissingWarehouse;
        const destination = self.getPtr(delivery.intent.destination) orelse return error.MissingWarehouse;
        const quantity = delivery.intent.quantity;
        if (quantity == 0 or delivery.cargo != quantity or delivery.remaining_promise != quantity or destination.incoming < quantity or
            source.obligations == 0 or destination.obligations == 0 or destination.material != delivery.intent.material or source.material != delivery.intent.material or
            @as(u32, destination.stock) + quantity > destination.physicalCapacity()) return error.InvalidDeliveryState;
        try source.ensureRevision();
        try destination.ensureRevision();
        // The delivery consumes its own promise, including after Stop/A=0.
        destination.incoming -= quantity;
        destination.stock += quantity;
        source.obligations -= 1;
        destination.obligations -= 1;
        source.revision += 1;
        destination.revision += 1;
        delivery.cargo = 0;
        delivery.remaining_promise = 0;
        delivery.complete = true;
        self.delivery_state.retireCompletedPrefix();
        self.commitChanged();
        return .applied;
    }

    /// Capture/load validation is allowed to scan task records; ordinary stock
    /// mutations and handovers use only local aggregates and matching records.
    pub fn validate(self: *const State, allocator: std.mem.Allocator) Error!void {
        if (self.next_id == 0 or self.records.count() > self.record_limit) return error.InvalidIdentity;
        try self.delivery_state.validate();
        const Accounting = struct { incoming: u32 = 0, obligations: u32 = 0 };
        var accounting: std.AutoHashMapUnmanaged(u64, Accounting) = .empty;
        defer accounting.deinit(allocator);
        try accounting.ensureTotalCapacity(allocator, self.records.count());
        var records = self.records.iterator();
        while (records.next()) |entry| {
            const record = entry.value_ptr.*;
            try record.validate();
            try record.geometry.validate(self.world_size);
            if (entry.key_ptr.* != record.identity.id or record.identity.id >= self.next_id or record.identity.world_session != self.world_session) return error.InvalidIdentity;
            accounting.putAssumeCapacityNoClobber(record.identity.id, .{});
        }
        var accepted = self.delivery_state.records.valueIterator();
        while (accepted.next()) |delivery| {
            if (delivery.complete) continue;
            if (delivery.intent.source.eql(delivery.intent.destination)) return error.InvalidDeliveryState;
            const source = self.get(delivery.intent.source) orelse return error.MissingWarehouse;
            const destination = self.get(delivery.intent.destination) orelse return error.MissingWarehouse;
            if (source.material != delivery.intent.material or destination.material != delivery.intent.material) return error.InvalidMaterial;
            const from = accounting.getPtr(source.identity.id).?;
            const to = accounting.getPtr(destination.identity.id).?;
            from.obligations = std.math.add(u32, from.obligations, 1) catch return error.InvalidObligations;
            to.obligations = std.math.add(u32, to.obligations, 1) catch return error.InvalidObligations;
            to.incoming = std.math.add(u32, to.incoming, delivery.remaining_promise) catch return error.InvalidObligations;
        }
        records = self.records.iterator();
        while (records.next()) |entry| {
            const counts = accounting.get(entry.key_ptr.*).?;
            if (entry.value_ptr.incoming != counts.incoming or entry.value_ptr.obligations != counts.obligations) return error.InvalidObligations;
        }
    }
};

test "warehouse aggregate APIs cover all supported footprint A C I states" {
    for (1..6) |width| for (1..6) |height| {
        const geometry = try Geometry.fromMinimum(.{ 128, 128, 128 }, .{ 10, 10, 10 }, .{ @intCast(width), @intCast(height) });
        const count = width * height;
        var record = try Record.init(.{ .world_session = 1, .kind = .warehouse, .id = 1, .lifetime = 1 }, geometry, .dirt);
        for (0..count + 1) |active| for (0..6 * count + 1) |stock| for (0..6 * count - stock + 1) |incoming| {
            record.active = @intCast(active);
            record.stock = @intCast(stock);
            record.incoming = @intCast(incoming);
            try record.validate();
            const total = stock + incoming;
            try std.testing.expectEqual(@as(u16, @intCast(4 * active -| total)), record.demand());
            try std.testing.expectEqual(@as(u16, @intCast(6 * active -| total)), record.admissionRoom());
            try std.testing.expectEqual(total + 1 <= 6 * active, record.canAdd(1));
            try std.testing.expect(!record.canAdd(0));
            if (record.admissionRoom() > 0) {
                try std.testing.expect(record.canAdd(record.admissionRoom()));
                try std.testing.expect(!record.canAdd(record.admissionRoom() + 1));
            }
        };
    };
}

fn testState() State {
    return State.init(11, .{ 128, 128, 128 });
}

fn testRegister(state: *State, minimum: Cell, size: [2]u8) !Record {
    return state.register(std.testing.allocator, try Geometry.fromMinimum(state.world_size, minimum, size), .dirt);
}

test "warehouse registration defaults and stopped empty management preserve identity" {
    var state = testState();
    defer state.deinit(std.testing.allocator);
    const first = try testRegister(&state, .{ 10, 10, 10 }, .{ 3, 3 });
    try std.testing.expect(first.enabled and first.active == 9 and first.stock == 0 and first.incoming == 0 and first.obligations == 0);
    try std.testing.expectError(error.NotStopped, state.unregister(std.testing.allocator, first.identity));
    const record = state.getPtr(first.identity).?;
    try record.put(.dirt, 20);
    _ = try record.setActive(0);
    _ = try record.setEnabled(false);
    try std.testing.expectError(error.CapacityExceeded, record.put(.dirt, 1));
    try std.testing.expectError(error.Busy, record.changeMaterial(.sand));
    try std.testing.expectEqual(BlockType.dirt, try record.take(20));
    _ = try record.changeMaterial(.pallet);
    try std.testing.expect(!record.enabled);
    _ = try state.unregister(std.testing.allocator, first.identity);
    const second = try testRegister(&state, .{ 10, 10, 10 }, .{ 3, 3 });
    try std.testing.expect(!first.identity.eql(second.identity));
    try std.testing.expect(second.enabled and second.active == 9);
    try std.testing.expect(state.get(first.identity) == null);
}

test "warehouse accepted delivery retains coherent cargo promise and obligations through restart stop and reduction" {
    const allocator = std.testing.allocator;
    var state = testState();
    defer state.deinit(allocator);
    const source = try testRegister(&state, .{ 10, 10, 10 }, .{ 3, 3 });
    const destination = try testRegister(&state, .{ 20, 10, 10 }, .{ 3, 3 });
    try state.getPtr(source.identity).?.put(.dirt, 40);
    try state.getPtr(destination.identity).?.put(.dirt, 20);
    try std.testing.expectEqual(Transition.applied, try state.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 8));
    try std.testing.expectEqual(Transition.replayed, try state.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 8));
    try std.testing.expectError(error.ConflictingDelivery, state.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 7));
    _ = try state.getPtr(destination.identity).?.setActive(4);
    _ = try state.getPtr(destination.identity).?.setEnabled(false);
    _ = try state.getPtr(source.identity).?.setEnabled(false);
    try std.testing.expectError(error.CapacityExceeded, state.getPtr(destination.identity).?.put(.dirt, 1));
    try std.testing.expectError(error.Stopped, state.startDelivery(allocator, 2, source.identity, destination.identity, .dirt, 1));
    try state.validate(allocator);
    var reopened = try state.clone(allocator);
    defer reopened.deinit(allocator);
    try reopened.validate(allocator);
    try std.testing.expectEqual(Transition.applied, try reopened.handover(1));
    try std.testing.expectEqual(Transition.replayed, try reopened.handover(1));
    try std.testing.expectError(error.RetiredDelivery, reopened.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 8));
    try reopened.validate(allocator);
    try std.testing.expectEqual(@as(u16, 32), reopened.get(source.identity).?.stock);
    try std.testing.expectEqual(@as(u16, 28), reopened.get(destination.identity).?.stock);
    try std.testing.expectEqual(@as(u16, 0), reopened.get(destination.identity).?.incoming);
    try std.testing.expect(!reopened.get(destination.identity).?.enabled);
    try std.testing.expectEqual(@as(u32, 0), reopened.get(source.identity).?.obligations);
}

test "warehouse oldest incomplete delivery bounds admission without dropping later completions" {
    const allocator = std.testing.allocator;
    var state = testState();
    defer state.deinit(allocator);
    state.delivery_state.record_limit = 2;
    const source = try testRegister(&state, .{ 10, 10, 10 }, .{ 3, 3 });
    const destination = try testRegister(&state, .{ 20, 10, 10 }, .{ 3, 3 });
    try state.getPtr(source.identity).?.put(.dirt, 12);
    _ = try state.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 2);
    _ = try state.startDelivery(allocator, 2, source.identity, destination.identity, .dirt, 3);
    _ = try state.handover(2);
    try std.testing.expectEqual(@as(u64, 0), state.delivery_state.completed_through);
    try std.testing.expectError(error.Busy, state.startDelivery(allocator, 3, source.identity, destination.identity, .dirt, 1));
    try std.testing.expectEqual(@as(u16, 7), state.get(source.identity).?.stock);
    try state.validate(allocator);
    _ = try state.handover(1);
    try std.testing.expectEqual(@as(u64, 2), state.delivery_state.completed_through);
    try std.testing.expectEqual(@as(u32, 0), state.delivery_state.records.count());
    _ = try state.startDelivery(allocator, 3, source.identity, destination.identity, .dirt, 1);
    try state.validate(allocator);
}

test "warehouse outgoing obligation protects an empty stopped source through handover" {
    const allocator = std.testing.allocator;
    var state = testState();
    defer state.deinit(allocator);
    const source = try testRegister(&state, .{ 10, 10, 10 }, .{ 1, 1 });
    const destination = try testRegister(&state, .{ 20, 10, 10 }, .{ 1, 1 });
    try state.getPtr(source.identity).?.put(.dirt, 4);
    _ = try state.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 4);
    _ = try state.getPtr(source.identity).?.setEnabled(false);
    try std.testing.expectEqual(@as(u16, 0), state.get(source.identity).?.stock);
    try std.testing.expectError(error.Busy, state.unregister(allocator, source.identity));
    try std.testing.expectError(error.Busy, state.getPtr(source.identity).?.changeMaterial(.sand));
    _ = try state.getPtr(destination.identity).?.setActive(0);
    _ = try state.getPtr(destination.identity).?.setEnabled(false);
    _ = try state.handover(1);
    _ = try state.unregister(allocator, source.identity);
    const replacement = try testRegister(&state, .{ 10, 10, 10 }, .{ 1, 1 });
    try std.testing.expect(!replacement.identity.eql(source.identity));
    try std.testing.expectEqual(Transition.replayed, try state.handover(1));
    try std.testing.expectEqual(@as(u16, 0), state.get(replacement.identity).?.stock);
    try std.testing.expectEqual(@as(u16, 4), state.get(destination.identity).?.stock);
    try state.validate(allocator);
}

test "warehouse revision exhaustion refuses changes before resource mutation" {
    const allocator = std.testing.allocator;
    var state = testState();
    defer state.deinit(allocator);
    const source = try testRegister(&state, .{ 10, 10, 10 }, .{ 1, 1 });
    const destination = try testRegister(&state, .{ 20, 10, 10 }, .{ 1, 1 });
    const record = state.getPtr(source.identity).?;
    record.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.RevisionExhausted, record.put(.dirt, 1));
    try std.testing.expectEqual(@as(u16, 0), record.stock);
    record.revision = 0;
    try record.put(.dirt, 4);
    state.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.RevisionExhausted, state.startDelivery(allocator, 1, source.identity, destination.identity, .dirt, 1));
    try std.testing.expectEqual(@as(u16, 4), state.get(source.identity).?.stock);
    try std.testing.expectEqual(@as(u16, 0), state.get(destination.identity).?.incoming);
    try std.testing.expectEqual(@as(u64, 1), state.delivery_state.next_id);
}

test "warehouse native capacity accounting includes eight discovery refs and retained delivery records" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    var state = State.init(11, .{ 2048, 2048, 2048 });
    var identities: [4096]Identity = undefined;
    for (&identities, 0..) |*identity, index| {
        const minimum: Cell = .{ @intCast(31 + (index % 16) * 64), @intCast(31 + ((index / 16) % 16) * 64), @intCast(31 + (index / 256) * 64) };
        const record = try state.register(allocator, try Geometry.fromMinimum(state.world_size, minimum, .{ 5, 5 }), .dirt);
        identity.* = record.identity;
        try state.getPtr(record.identity).?.put(.dirt, 2);
    }
    for (identities, 0..) |identity, index| {
        _ = try state.startDelivery(allocator, index + 1, identity, identities[(index + 1) % identities.len], .dirt, 1);
        if (index != 0) _ = try state.handover(index + 1);
    }
    try state.validate(allocator);
    const live_bytes = counted.allocated_bytes - counted.freed_bytes;
    var reference_count: usize = 0;
    var reference_capacity: usize = 0;
    var lists = state.claims.by_chunk.valueIterator();
    while (lists.next()) |list| {
        reference_count += list.items.len;
        reference_capacity += list.capacity;
    }
    try std.testing.expectEqual(@as(usize, 4096 * 8), reference_count);
    try std.testing.expectEqual(reference_count, reference_capacity);
    try std.testing.expectEqual(@as(u32, 4096), state.delivery_state.records.count());
    std.debug.print("\nwarehouse cap native retained={d} estimate={d}; record={d} layout={d} delivery={d} ref={d}; capacities warehouse={d} layout={d} delivery={d} chunk={d} refs={d}\n", .{ live_bytes, state.estimatedOwnedBytes(), @sizeOf(Record), @sizeOf(layout.Layout), @sizeOf(deliveries.Delivery), @sizeOf(claims_module.Reference), state.records.capacity(), state.layouts.capacity(), state.delivery_state.records.capacity(), state.claims.by_chunk.capacity(), reference_capacity });
    state.deinit(allocator);
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test {
    _ = @import("warehouse_recognition.zig");
    _ = @import("warehouse_claims.zig");
    _ = @import("persistence/warehouses.zig");
}
