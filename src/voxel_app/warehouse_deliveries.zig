//! Minimal accepted cargo/promise state, not a logistics scheduler. The caller
//! establishes routing and other start prerequisites before the coherent start.
const std = @import("std");
pub const Identity = @import("construction_state.zig").Identity;
pub const BlockType = @import("engine").voxel_chunk.BlockType;

pub const Intent = struct {
    source: Identity,
    destination: Identity,
    material: BlockType,
    quantity: u16,
};

pub const Delivery = struct {
    id: u64,
    intent: Intent,
    cargo: u16,
    remaining_promise: u16,
    complete: bool = false,
};

pub const Transition = enum { applied, replayed };
pub const Error = error{ Busy, InvalidDeliveryId, RetiredDelivery, ConflictingDelivery, DeliveryIdExhausted, MissingDelivery, InvalidDeliveryState };

pub const Store = struct {
    records: std.AutoHashMapUnmanaged(u64, Delivery) = .empty,
    next_id: u64 = 1,
    completed_through: u64 = 0,
    record_limit: usize = 4096,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn clone(self: Store, allocator: std.mem.Allocator) !Store {
        var result = self;
        result.records = try self.records.clone(allocator);
        return result;
    }

    /// Retired IDs cannot be relabeled with a new intent. A live retry must
    /// match its complete original intent, even after completion.
    pub fn existing(self: *const Store, id: u64, intent: Intent) Error!?Delivery {
        if (id == 0) return error.InvalidDeliveryId;
        if (id <= self.completed_through) return error.RetiredDelivery;
        if (self.records.get(id)) |record| {
            if (!std.meta.eql(record.intent, intent)) return error.ConflictingDelivery;
            return record;
        }
        if (id != self.next_id) return error.InvalidDeliveryId;
        return null;
    }

    pub fn prepare(self: *Store, allocator: std.mem.Allocator) !void {
        if (self.records.count() >= self.record_limit) return error.Busy;
        if (self.next_id == std.math.maxInt(u64)) return error.DeliveryIdExhausted;
        try self.records.ensureUnusedCapacity(allocator, 1);
    }

    pub fn install(self: *Store, delivery: Delivery) void {
        std.debug.assert(delivery.id == self.next_id);
        self.records.putAssumeCapacityNoClobber(delivery.id, delivery);
        self.next_id += 1;
    }

    /// An old unfinished delivery can pin later completed IDs. The retained
    /// record cap then refuses new starts without discarding any accepted cargo.
    pub fn retireCompletedPrefix(self: *Store) void {
        while (self.records.get(self.completed_through + 1)) |record| {
            if (!record.complete) break;
            _ = self.records.remove(record.id);
            self.completed_through += 1;
        }
    }

    pub fn validate(self: *const Store) Error!void {
        if (self.next_id == 0 or self.completed_through >= self.next_id or self.records.count() > self.record_limit) return error.InvalidDeliveryState;
        if (self.next_id - self.completed_through - 1 != self.records.count()) return error.InvalidDeliveryState;
        var iterator = self.records.iterator();
        while (iterator.next()) |entry| {
            const record = entry.value_ptr.*;
            if (entry.key_ptr.* != record.id or record.id <= self.completed_through or record.id >= self.next_id or record.intent.quantity == 0 or !record.intent.material.canStoreInWarehouse()) return error.InvalidDeliveryState;
            if (record.complete) {
                if (record.cargo != 0 or record.remaining_promise != 0) return error.InvalidDeliveryState;
            } else if (record.cargo != record.intent.quantity or record.remaining_promise != record.intent.quantity) return error.InvalidDeliveryState;
        }
    }
};
