//! External intent bookkeeping. The caller serializes access; automatic
//! simulation work uses its own local lifecycle and never enters this ledger.
const std = @import("std");
const world = @import("world.zig");
const rules = @import("block_rules.zig");
const blueprint = @import("blueprint.zig");
const state = @import("construction_state.zig");
pub const Identity = state.CommandIdentity;

pub const Intent = union(enum) {
    operation: struct { operation: world.BlockOperation, target: ?state.Identity = null },
    apply: struct { owner: u64, definition_id: u64, origin: [3]u32, rotation: u2 },
    save: struct { owner: u64, name: []const u8, definition: blueprint.Definition },

    pub fn eql(a: Intent, b: Intent) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .operation => |value| std.meta.eql(value, b.operation),
            .apply => |value| std.meta.eql(value, b.apply),
            .save => |value| value.owner == b.save.owner and std.mem.eql(u8, value.name, b.save.name) and
                std.meta.eql(value.definition.size, b.save.definition.size) and value.definition.target_count == b.save.definition.target_count and
                std.mem.eql(rules.BlockType, value.definition.cells, b.save.definition.cells),
        };
    }

    fn clone(self: Intent, allocator: std.mem.Allocator) !Intent {
        if (self != .save) return self;
        const name = try allocator.dupe(u8, self.save.name);
        errdefer allocator.free(name);
        var definition = self.save.definition;
        definition.cells = try allocator.dupe(rules.BlockType, definition.cells);
        return .{ .save = .{ .owner = self.save.owner, .name = name, .definition = definition } };
    }

    fn deinit(self: Intent, allocator: std.mem.Allocator) void {
        if (self == .save) {
            allocator.free(self.save.name);
            allocator.free(self.save.definition.cells);
        }
    }

    fn bytes(self: Intent) usize {
        // Admission owns both the queued candidate and this canonical retry
        // copy. Keep both reservations until acknowledgment, even after the
        // queued copy has moved into the separately bounded definition library.
        return if (self == .save) (self.save.name.len +| self.save.definition.cells.len) *| 2 else 0;
    }
};

pub const Outcome = union(enum) {
    operation: struct { status: world.OperationStatus, failure: ?rules.Failure = null, mined_type: ?rules.BlockType = null },
    blueprint: @import("blueprint_result.zig").Result,
};
pub const Submission = struct {
    request_id: u64,
    command: Identity,
    disposition: enum { queued, pending, replayed },
    outcome: ?Outcome = null,
};
pub const Error = error{ Busy, OutOfMemory, StaleCommand, ConflictingCommand, InvalidCommandSession, OutOfOrderCommand, CommandSequenceExhausted, CommandResyncRequired };

pub const Budget = struct {
    records: usize = 0,
    bytes: usize = 0,
    record_limit: usize = 256,
    byte_limit: usize = 32 * 1024 * 1024,
};

pub const Record = struct {
    sequence: u64,
    request_id: u64,
    intent: Intent,
    outcome: ?Outcome = null,
    acknowledged: bool = false,
    delivered: bool = false,
};

pub const Ledger = struct {
    records: std.ArrayList(Record) = .empty,
    next_sequence: u64 = 1,
    retired_through: u64 = 0,

    pub fn trimEmpty(self: *Ledger, allocator: std.mem.Allocator, budget: *Budget) void {
        if (self.records.items.len != 0) return;
        budget.bytes -= self.records.capacity * @sizeOf(Record);
        self.records.deinit(allocator);
        self.records = .empty;
    }

    pub fn deinit(self: *Ledger, allocator: std.mem.Allocator, budget: *Budget) void {
        for (self.records.items) |record| {
            record.intent.deinit(allocator);
            budget.bytes -= record.intent.bytes();
        }
        budget.records -= self.records.items.len;
        budget.bytes -= self.records.capacity * @sizeOf(Record);
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn reserve(self: *Ledger, allocator: std.mem.Allocator, budget: *Budget, additional: usize) Error!void {
        if (additional > budget.record_limit -| budget.records) return error.Busy;
        const wanted = self.records.items.len + additional;
        if (wanted <= self.records.capacity) return;
        const extra = (wanted - self.records.capacity) * @sizeOf(Record);
        if (extra > budget.byte_limit -| budget.bytes) return error.Busy;
        try self.records.ensureTotalCapacityPrecise(allocator, wanted);
        budget.bytes += extra;
    }

    pub fn existing(self: *Ledger, identity: Identity, intent: Intent) Error!?Submission {
        if (identity.sequence <= self.retired_through) return error.StaleCommand;
        for (self.records.items) |record| if (record.sequence == identity.sequence) {
            if (!record.intent.eql(intent)) return error.ConflictingCommand;
            return .{ .request_id = record.request_id, .command = identity, .disposition = if (record.outcome != null) .replayed else .pending, .outcome = record.outcome };
        };
        if (identity.sequence != self.next_sequence) return error.OutOfOrderCommand;
        return null;
    }

    pub fn admit(self: *Ledger, allocator: std.mem.Allocator, budget: *Budget, identity: Identity, request_id: u64, intent: Intent) Error!Submission {
        if (try self.existing(identity, intent)) |found| return found;
        if (self.next_sequence == std.math.maxInt(u64)) return error.CommandSequenceExhausted;
        try self.reserve(allocator, budget, 1);
        const bytes = intent.bytes();
        if (bytes > budget.byte_limit -| budget.bytes) return error.Busy;
        const copy = try intent.clone(allocator);
        self.records.appendAssumeCapacity(.{ .sequence = identity.sequence, .request_id = request_id, .intent = copy });
        budget.records += 1;
        budget.bytes += bytes;
        self.next_sequence += 1;
        return .{ .request_id = request_id, .command = identity, .disposition = .queued };
    }

    pub fn complete(self: *Ledger, sequence: u64, outcome: Outcome) void {
        for (self.records.items) |*record| if (record.sequence == sequence) {
            std.debug.assert(record.outcome == null);
            record.outcome = outcome;
            return;
        };
        unreachable;
    }

    pub fn markDelivered(self: *Ledger, sequence: u64) void {
        for (self.records.items) |*record| if (record.sequence == sequence) {
            std.debug.assert(record.outcome != null);
            record.delivered = true;
            return;
        };
    }

    pub fn acknowledge(self: *Ledger, allocator: std.mem.Allocator, budget: *Budget, sequence: u64) bool {
        for (self.records.items) |*record| if (record.sequence == sequence) {
            if (record.outcome == null) return false;
            record.acknowledged = true;
            break;
        };
        while (self.records.items.len != 0 and self.records.items[0].acknowledged) {
            const retired = self.records.orderedRemove(0);
            self.retired_through = retired.sequence;
            retired.intent.deinit(allocator);
            budget.records -= 1;
            budget.bytes -= retired.intent.bytes();
        }
        if (self.records.items.len == 0 and self.records.capacity != 0) {
            budget.bytes -= self.records.capacity * @sizeOf(Record);
            self.records.deinit(allocator);
            self.records = .empty;
        }
        return sequence <= self.retired_through;
    }
};

test "command ledger binds whole typed intents and retires only acknowledged contiguous results" {
    const a = std.testing.allocator;
    var budget: Budget = .{ .record_limit = 2 };
    var ledger: Ledger = .{};
    defer ledger.deinit(a, &budget);
    const first: Identity = .{ .world_session = 7, .client_session = 9, .sequence = 1 };
    const intent: Intent = .{ .apply = .{ .owner = 1, .definition_id = 2, .origin = .{ 3, 4, 5 }, .rotation = 0 } };
    try std.testing.expectEqual(.queued, (try ledger.admit(a, &budget, first, 10, intent)).disposition);
    try std.testing.expectEqual(.pending, (try ledger.admit(a, &budget, first, 11, intent)).disposition);
    var changed = intent;
    changed.apply.rotation = 1;
    try std.testing.expectError(error.ConflictingCommand, ledger.admit(a, &budget, first, 12, changed));
    const second: Identity = .{ .world_session = 7, .client_session = 9, .sequence = 2 };
    _ = try ledger.admit(a, &budget, second, 11, intent);
    ledger.complete(2, .{ .blueprint = .{ .request_id = 11, .command = second, .kind = .apply, .status = .success, .instance_id = 123 } });
    try std.testing.expect(!ledger.acknowledge(a, &budget, 2));
    try std.testing.expectEqual(@as(u64, 0), ledger.retired_through);
    try std.testing.expect(!ledger.acknowledge(a, &budget, 1));
    ledger.complete(1, .{ .blueprint = .{ .request_id = 10, .command = first, .kind = .apply, .status = .success, .instance_id = 122 } });
    const replay = try ledger.admit(a, &budget, first, 99, intent);
    try std.testing.expectEqual(.replayed, replay.disposition);
    try std.testing.expectEqual(@as(u64, 10), replay.request_id);
    try std.testing.expectEqual(@as(?u64, 122), replay.outcome.?.blueprint.instance_id);
    try std.testing.expect(ledger.acknowledge(a, &budget, 1));
    try std.testing.expectEqual(@as(u64, 2), ledger.retired_through);
    try std.testing.expectEqual(@as(usize, 0), budget.records);
    try std.testing.expectEqual(@as(usize, 0), budget.bytes);
    try std.testing.expectError(error.StaleCommand, ledger.admit(a, &budget, first, 100, changed));
}

test "command ledger shares bounds and distinguishes target kind lifetime and payload" {
    const a = std.testing.allocator;
    var budget: Budget = .{ .record_limit = 1 };
    var first: Ledger = .{};
    defer first.deinit(a, &budget);
    var second: Ledger = .{};
    defer second.deinit(a, &budget);
    const identity: Identity = .{ .world_session = 7, .client_session = 9, .sequence = 1 };
    const intent: Intent = .{ .operation = .{ .operation = .{ .block = .{ 1, 2, 3 }, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 5, .cell_index = 0 } }, .target = .{ .world_session = 7, .id = 5, .lifetime = 5 } } };
    _ = try first.admit(a, &budget, identity, 1, intent);
    var changed = intent;
    changed.operation.target.?.kind = .warehouse;
    try std.testing.expectError(error.ConflictingCommand, first.admit(a, &budget, identity, 2, changed));
    changed = intent;
    changed.operation.target.?.lifetime += 1;
    try std.testing.expectError(error.ConflictingCommand, first.admit(a, &budget, identity, 2, changed));
    changed = intent;
    changed.operation.operation.action.put = .dirt;
    try std.testing.expectError(error.ConflictingCommand, first.admit(a, &budget, identity, 2, changed));
    try std.testing.expectError(error.Busy, second.admit(a, &budget, identity, 1, intent));
    try std.testing.expectEqual(@as(u64, 1), second.next_sequence);
}

fn exerciseSaveOwnership(allocator: std.mem.Allocator) !void {
    var budget: Budget = .{};
    var ledger: Ledger = .{};
    defer ledger.deinit(allocator, &budget);
    const identity: Identity = .{ .world_session = 7, .client_session = 9, .sequence = 1 };
    const intent: Intent = .{ .save = .{ .owner = 1, .name = "immutable", .definition = .{ .size = .{ 2, 1, 1 }, .cells = &.{ .planks, .planks }, .target_count = 2 } } };
    _ = try ledger.admit(allocator, &budget, identity, 1, intent);
    try std.testing.expect(ledger.records.items[0].intent.save.name.ptr != intent.save.name.ptr);
    var changed = intent;
    changed.save.definition.cells = &.{ .planks, .rebar };
    try std.testing.expectError(error.ConflictingCommand, ledger.admit(allocator, &budget, identity, 2, changed));
}

test "command ledger exact Save ownership survives every allocation denial" {
    try exerciseSaveOwnership(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSaveOwnership, .{});
    var ledger: Ledger = .{};
    var budget: Budget = .{ .byte_limit = @sizeOf(Record) - 1 };
    defer ledger.deinit(std.testing.allocator, &budget);
    try std.testing.expectError(error.Busy, ledger.reserve(std.testing.allocator, &budget, 1));
    try std.testing.expectEqual(@as(usize, 0), budget.bytes);
}

test "command ledger byte cap shares record capacity and both Save payload reservations" {
    const a = std.testing.allocator;
    const identity: Identity = .{ .world_session = 7, .client_session = 9, .sequence = 1 };
    const save: Intent = .{ .save = .{ .owner = 1, .name = "Save", .definition = .{ .size = .{ 1, 1, 1 }, .cells = &.{.planks}, .target_count = 1 } } };
    const exact = @sizeOf(Record) + 2 * (save.save.name.len + save.save.definition.cells.len);
    var budget: Budget = .{ .byte_limit = exact - 1 };
    var ledger: Ledger = .{};
    defer ledger.deinit(a, &budget);
    try std.testing.expectError(error.Busy, ledger.admit(a, &budget, identity, 1, save));
    ledger.trimEmpty(a, &budget);
    try std.testing.expectEqual(@as(usize, 0), budget.bytes);
    budget.byte_limit = exact;
    _ = try ledger.admit(a, &budget, identity, 1, save);
    try std.testing.expectEqual(exact, budget.bytes);
    const next: Identity = .{ .world_session = 7, .client_session = 9, .sequence = 2 };
    const operation: Intent = .{ .operation = .{ .operation = .{ .block = .{ 1, 2, 3 }, .action = .remove } } };
    try std.testing.expectError(error.Busy, ledger.admit(a, &budget, next, 2, operation));
    try std.testing.expectEqual(@as(u64, 2), ledger.next_sequence);
}
