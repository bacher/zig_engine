//! Compact canonical warehouse and accepted-cargo records. This codec is shared
//! by capture and recovery; it never stores derived claims or rendered cubes.
const std = @import("std");
const format = @import("format.zig");
const model = @import("../warehouse_state.zig");
const deliveries = @import("../warehouse_deliveries.zig");
pub const Limits = struct { max_warehouses: usize = 4096, max_deliveries: usize = 4096, max_bytes: usize = 2 * 1024 * 1024 };
const header_size = 48;
const record_size = 51;
const delivery_size = 48;

pub fn encodedSize(warehouse_count: usize, delivery_count: usize) !usize {
    return std.math.add(usize, header_size, try std.math.add(usize, try std.math.mul(usize, record_size, warehouse_count), try std.math.mul(usize, delivery_size, delivery_count)));
}

fn putIdentity(bytes: []u8, pos: *usize, identity: model.Identity) void {
    format.put(u64, bytes, pos, identity.id);
    format.put(u64, bytes, pos, identity.lifetime);
}
fn readIdentity(reader: *format.Reader, session: u64) !model.Identity {
    const identity: model.Identity = .{ .world_session = session, .kind = .warehouse, .id = try reader.int(u64), .lifetime = try reader.int(u64) };
    if (identity.id == 0 or identity.lifetime == 0) return error.InvalidWarehouse;
    return identity;
}
fn sortedKeys(a: std.mem.Allocator, map: anytype) ![]u64 {
    const result = try a.alloc(u64, map.count());
    var keys = map.keyIterator();
    var i: usize = 0;
    while (keys.next()) |key| : (i += 1) result[i] = key.*;
    std.mem.sort(u64, result, {}, std.sort.asc(u64));
    return result;
}

pub fn encodeState(a: std.mem.Allocator, state: *const model.State, limits: Limits) ![]u8 {
    if (state.records.count() > limits.max_warehouses or state.delivery_state.records.count() > limits.max_deliveries) return error.Capacity;
    const size = try encodedSize(state.records.count(), state.delivery_state.records.count());
    if (size > limits.max_bytes) return error.Capacity;
    try state.validate(a);
    const warehouses = try sortedKeys(a, state.records);
    defer a.free(warehouses);
    const tasks = try sortedKeys(a, state.delivery_state.records);
    defer a.free(tasks);
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    @memcpy(bytes[0..8], "ZGWARE01");
    var pos: usize = 8;
    format.put(u64, bytes, &pos, state.next_id);
    format.put(u64, bytes, &pos, state.revision);
    format.put(u64, bytes, &pos, state.delivery_state.next_id);
    format.put(u64, bytes, &pos, state.delivery_state.completed_through);
    format.put(u32, bytes, &pos, @intCast(warehouses.len));
    format.put(u32, bytes, &pos, @intCast(tasks.len));
    for (warehouses) |id| {
        const record = state.records.get(id).?;
        putIdentity(bytes, &pos, record.identity);
        for (record.geometry.origin) |coordinate| format.put(u32, bytes, &pos, coordinate);
        inline for (.{ "xmin", "xmax", "ymin", "ymax" }) |field| format.put(i8, bytes, &pos, @field(record.geometry.bounds, field));
        format.put(u8, bytes, &pos, @intFromEnum(record.material));
        format.put(u16, bytes, &pos, record.stock);
        format.put(u16, bytes, &pos, record.incoming);
        format.put(u8, bytes, &pos, record.active);
        format.put(u8, bytes, &pos, @intFromBool(record.enabled));
        format.put(u32, bytes, &pos, record.obligations);
        format.put(u64, bytes, &pos, record.revision);
    }
    for (tasks) |id| {
        const task = state.delivery_state.records.get(id).?;
        format.put(u64, bytes, &pos, task.id);
        putIdentity(bytes, &pos, task.intent.source);
        putIdentity(bytes, &pos, task.intent.destination);
        format.put(u8, bytes, &pos, @intFromEnum(task.intent.material));
        format.put(u16, bytes, &pos, task.intent.quantity);
        format.put(u16, bytes, &pos, task.cargo);
        format.put(u16, bytes, &pos, task.remaining_promise);
        format.put(u8, bytes, &pos, @intFromBool(task.complete));
    }
    std.debug.assert(pos == bytes.len);
    return bytes;
}

fn readMaterial(reader: *format.Reader) !model.BlockType {
    const raw = try reader.int(u8);
    if (!format.validBlockMaterial(raw)) return error.InvalidWarehouse;
    const material: model.BlockType = @enumFromInt(raw);
    if (!material.canStoreInWarehouse()) return error.InvalidWarehouse;
    return material;
}
fn readBool(reader: *format.Reader) !bool {
    return switch (try reader.int(u8)) {
        0 => false,
        1 => true,
        else => error.InvalidWarehouse,
    };
}

/// World sessions are deliberately renewed after restart. Persistent task and
/// registration identities keep their stable id/lifetime within the new session.
pub fn decodeState(a: std.mem.Allocator, bytes: []const u8, world_size: [3]u32, session: u64, limits: Limits) !model.State {
    var state = model.State.init(session, world_size);
    state.record_limit = limits.max_warehouses;
    state.delivery_state.record_limit = limits.max_deliveries;
    errdefer state.deinit(a);
    if (bytes.len == 0) return state;
    if (bytes.len > limits.max_bytes) return error.Capacity;
    var reader: format.Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.take(8), "ZGWARE01")) return error.InvalidWarehouse;
    state.next_id = try reader.int(u64);
    state.revision = try reader.int(u64);
    state.delivery_state.next_id = try reader.int(u64);
    state.delivery_state.completed_through = try reader.int(u64);
    const warehouse_count = try reader.int(u32);
    const delivery_count = try reader.int(u32);
    if (warehouse_count > limits.max_warehouses or delivery_count > limits.max_deliveries or bytes.len != try encodedSize(warehouse_count, delivery_count)) return error.InvalidWarehouse;
    try state.records.ensureTotalCapacity(a, warehouse_count);
    var previous: u64 = 0;
    for (0..warehouse_count) |_| {
        const identity = try readIdentity(&reader, session);
        if (identity.id <= previous) return error.InvalidWarehouse;
        previous = identity.id;
        var record: model.Record = .{ .identity = identity, .geometry = undefined, .material = undefined, .active = undefined };
        for (&record.geometry.origin) |*coordinate| coordinate.* = try reader.int(u32);
        inline for (.{ "xmin", "xmax", "ymin", "ymax" }) |field| @field(record.geometry.bounds, field) = try reader.int(i8);
        record.material = try readMaterial(&reader);
        record.stock = try reader.int(u16);
        record.incoming = try reader.int(u16);
        record.active = try reader.int(u8);
        record.enabled = try readBool(&reader);
        record.obligations = try reader.int(u32);
        record.revision = try reader.int(u64);
        state.records.putAssumeCapacityNoClobber(identity.id, record);
    }
    try state.delivery_state.records.ensureTotalCapacity(a, delivery_count);
    previous = 0;
    for (0..delivery_count) |_| {
        const id = try reader.int(u64);
        if (id <= previous) return error.InvalidWarehouse;
        previous = id;
        const source = try readIdentity(&reader, session);
        const destination = try readIdentity(&reader, session);
        if (source.id >= state.next_id or destination.id >= state.next_id or source.eql(destination)) return error.InvalidWarehouse;
        const material = try readMaterial(&reader);
        const quantity = try reader.int(u16);
        const task: deliveries.Delivery = .{ .id = id, .intent = .{ .source = source, .destination = destination, .material = material, .quantity = quantity }, .cargo = try reader.int(u16), .remaining_promise = try reader.int(u16), .complete = try readBool(&reader) };
        state.delivery_state.records.putAssumeCapacityNoClobber(id, task);
    }
    try reader.done();
    try state.validate(a);
    try state.rebuildClaims(a);
    return state;
}

test "warehouse codec restores one cargo promise cut under a fresh session" {
    const a = std.testing.allocator;
    var state = model.State.init(7, .{ 128, 128, 128 });
    defer state.deinit(a);
    const first = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 10, 10, 31 }, .{ 2, 2 }), .dirt);
    const second = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 20, 10, 31 }, .{ 2, 2 }), .dirt);
    try state.getPtr(first.identity).?.put(.dirt, 12);
    _ = try state.startDelivery(a, 1, first.identity, second.identity, .dirt, 6);
    _ = try state.getPtr(second.identity).?.setActive(0);
    _ = try state.getPtr(second.identity).?.setEnabled(false);
    const bytes = try encodeState(a, &state, .{});
    defer a.free(bytes);
    var restored = try decodeState(a, bytes, state.world_size, 8, .{});
    defer restored.deinit(a);
    try std.testing.expect(restored.get(second.identity) == null);
    const destination = restored.records.get(second.identity.id).?;
    try std.testing.expect(!destination.enabled and destination.active == 0 and destination.stock == 0 and destination.incoming == 6);
    try std.testing.expect(restored.claims.claimed(state.world_size[0], .{ 19, 9, 36 }));
    _ = try restored.handover(1);
    _ = try restored.handover(1);
    try std.testing.expectEqual(@as(u16, 6), restored.records.get(second.identity.id).?.stock);
    try std.testing.expectEqual(@as(u16, 0), restored.records.get(second.identity.id).?.incoming);
    const final_bytes = try encodeState(a, &restored, .{});
    defer a.free(final_bytes);
    var final = try decodeState(a, final_bytes, state.world_size, 9, .{});
    defer final.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), final.delivery_state.completed_through);
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    var state = model.State.init(7, .{ 128, 128, 128 });
    defer state.deinit(a);
    const first = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 31, 31, 31 }, .{ 2, 2 }), .pallet);
    const second = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 63, 31, 31 }, .{ 2, 2 }), .pallet);
    try state.getPtr(first.identity).?.put(.pallet, 8);
    _ = try state.startDelivery(a, 1, first.identity, second.identity, .pallet, 3);
    const encoded = try encodeState(a, &state, .{});
    defer a.free(encoded);
    var decoded = try decodeState(a, encoded, state.world_size, 8, .{});
    defer decoded.deinit(a);
    _ = try decoded.handover(1);
    try decoded.validate(a);
}

test "warehouse capture codec owns no partial state after every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRoundtrip, .{});
}

test "warehouse codec rejects malformed aggregates task highwaters duplicate ids and truncation" {
    const a = std.testing.allocator;
    var state = model.State.init(7, .{ 128, 128, 128 });
    defer state.deinit(a);
    _ = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 10, 10, 10 }, .{ 1, 1 }), .dirt);
    const bytes = try encodeState(a, &state, .{});
    defer a.free(bytes);
    for (0..bytes.len) |cut| {
        if (cut == 0) continue; // Empty initial state is an explicit valid representation.
        if (decodeState(a, bytes[0..cut], state.world_size, 8, .{})) |decoded| {
            var bad = decoded;
            bad.deinit(a);
            return error.AcceptedTruncatedWarehouse;
        } else |_| {}
    }
    const malformed = try a.dupe(u8, bytes);
    defer a.free(malformed);
    // Incoming and obligations cannot exist without a matching accepted task.
    malformed[header_size + 35] = 1;
    try std.testing.expectError(error.InvalidObligations, decodeState(a, malformed, state.world_size, 8, .{}));
    @memcpy(malformed, bytes);
    var pos: usize = 24; // delivery next_id
    format.put(u64, malformed, &pos, 2);
    try std.testing.expectError(error.InvalidDeliveryState, decodeState(a, malformed, state.world_size, 8, .{}));
    @memcpy(malformed, bytes);
    malformed[header_size] = 0; // nonzero sorted registration ids
    try std.testing.expectError(error.InvalidWarehouse, decodeState(a, malformed, state.world_size, 8, .{}));
    try std.testing.expectError(error.Capacity, decodeState(a, bytes, state.world_size, 8, .{ .max_bytes = bytes.len - 1 }));
}

test "warehouse codec preserves pinned completed tasks whose endpoint has unregistered" {
    const a = std.testing.allocator;
    var state = model.State.init(7, .{ 128, 128, 128 });
    defer state.deinit(a);
    const source = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 10, 10, 70 }, .{ 1, 1 }), .dirt);
    const first = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 20, 10, 70 }, .{ 1, 1 }), .dirt);
    const second = try state.register(a, try model.Geometry.fromMinimum(state.world_size, .{ 30, 10, 70 }, .{ 1, 1 }), .dirt);
    try state.getPtr(source.identity).?.put(.dirt, 2);
    _ = try state.startDelivery(a, 1, source.identity, first.identity, .dirt, 1);
    _ = try state.startDelivery(a, 2, source.identity, second.identity, .dirt, 1);
    _ = try state.handover(2);
    _ = try state.getPtr(second.identity).?.setEnabled(false);
    _ = try state.getPtr(second.identity).?.take(1);
    _ = try state.unregister(a, second.identity);
    const bytes = try encodeState(a, &state, .{});
    defer a.free(bytes);
    var decoded = try decodeState(a, bytes, state.world_size, 8, .{});
    defer decoded.deinit(a);
    try std.testing.expect(decoded.delivery_state.records.get(2).?.complete);
    try std.testing.expect(decoded.records.get(second.identity.id) == null);
    _ = try decoded.handover(1);
    try std.testing.expectEqual(@as(u64, 2), decoded.delivery_state.completed_through);
    const malformed = try a.dupe(u8, bytes);
    defer a.free(malformed);
    @memset(malformed[header_size + 2 * record_size + delivery_size + 8 ..][0..8], 0);
    try std.testing.expectError(error.InvalidWarehouse, decodeState(a, malformed, state.world_size, 8, .{}));
}

/// Conservative additional peak for validating a frozen snapshot. This covers
/// record/layout/task tables, eight discovery entries per warehouse, hash growth
/// overlap, and linear aggregate scratch. The measured 4096+4096 retained state
/// is about 5.95 MB; the bound also covers transient allocation overlap.
pub fn preparationMemoryBound(bytes: []const u8, limits: Limits) !usize {
    if (bytes.len == 0) return 0;
    if (bytes.len < header_size or bytes.len > limits.max_bytes) return error.InvalidWarehouse;
    const warehouses = std.mem.readInt(u32, bytes[40..44], .little);
    const tasks = std.mem.readInt(u32, bytes[44..48], .little);
    if (warehouses > limits.max_warehouses or tasks > limits.max_deliveries or bytes.len != try encodedSize(warehouses, tasks)) return error.Capacity;
    return preparationMemoryBoundCounts(warehouses, tasks, limits);
}

/// Count-only form admits capture before its encoded snapshot is allocated.
pub fn preparationMemoryBoundCounts(warehouses: usize, tasks: usize, limits: Limits) !usize {
    if (warehouses > limits.max_warehouses or tasks > limits.max_deliveries or try encodedSize(warehouses, tasks) > limits.max_bytes) return error.Capacity;
    return std.math.add(usize, 512, try std.math.add(usize, try std.math.mul(usize, warehouses, 2048), try std.math.mul(usize, tasks, 512)));
}

test "warehouse compact capture and validation stay within the full capacity transient bound" {
    const Budget = @import("budget.zig").Budget;
    var meter = Budget.init(std.testing.allocator, 128 * 1024 * 1024);
    const a = meter.allocator();
    {
        var state = model.State.init(11, .{ 2048, 2048, 2048 });
        defer state.deinit(a);
        var identities: [4096]model.Identity = undefined;
        for (&identities, 0..) |*identity, index| {
            const minimum: model.Cell = .{ @intCast(31 + index % 16 * 64), @intCast(31 + index / 16 % 16 * 64), @intCast(31 + index / 256 * 64) };
            const record = try state.register(a, try model.Geometry.fromMinimum(state.world_size, minimum, .{ 5, 5 }), .dirt);
            identity.* = record.identity;
            try state.getPtr(record.identity).?.put(.dirt, 2);
        }
        for (identities, 0..) |identity, index| {
            _ = try state.startDelivery(a, index + 1, identity, identities[(index + 1) % identities.len], .dirt, 1);
            if (index != 0) _ = try state.handover(index + 1);
        }
        const retained = meter.stats().used;
        meter.peak.store(retained, .release);
        const encoded = try encodeState(a, &state, .{});
        defer a.free(encoded);
        const encoding_peak = meter.stats().peak - retained;
        // Capture owns one frozen byte image while Store prepares its immutable
        // replacement and validates/rebuilds a temporary derived state.
        const replacement = try a.dupe(u8, encoded);
        defer a.free(replacement);
        var decoded = try decodeState(a, encoded, state.world_size, 12, .{});
        defer decoded.deinit(a);
        const transient = meter.stats().peak - retained;
        const admitted = 2 * encoded.len + try preparationMemoryBound(encoded, .{});
        try std.testing.expect(transient <= admitted);
        try std.testing.expectEqual(@as(usize, 405552), encoded.len);
        std.debug.print("\nwarehouse capture capacity retained_bytes={d} encoded_bytes={d} encoding_peak_extra_bytes={d} validation_peak_extra_bytes={d} admitted_extra_bytes={d}\n", .{ retained, encoded.len, encoding_peak, transient, admitted });
    }
    try std.testing.expectEqual(@as(usize, 0), meter.stats().used);
    try std.testing.expectEqual(@as(u64, 0), meter.stats().rejections);
}
