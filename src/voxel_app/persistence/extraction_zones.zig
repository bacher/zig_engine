//! Canonical zone records and sparse occupied cells. Derived claims, dependent
//! indexes and deadline queues are rebuilt from the durable state.
const std = @import("std");
const engine = @import("engine");
const format = @import("format.zig");
const geometry = @import("../extraction_zone.zig");
const model = @import("../extraction_zone_state.zig");

pub const Limits = struct {
    max_bytes: usize = 32 * 1024 * 1024,
    zone_budgets: geometry.Budgets = .{},
};
const magic = "ZGEXTR01";
const header_size = 24;
const zone_size = 25;
const chunk_header_size = 14;
const custom_wire_material = 24;

const CellFlags = packed struct(u8) {
    material: u5,
    constructed: bool,
    slope: bool,
    grass: bool,
};

pub fn encodedSize(state: *const model.State, limits: Limits) !usize {
    if (state.records.items.len == 0) return 0;
    var size = try std.math.add(usize, header_size, try std.math.mul(usize, zone_size, state.records.items.len));
    var chunks = state.by_chunk.valueIterator();
    while (chunks.next()) |chunk| {
        if (chunk.cells.count() == 0) continue;
        size = try std.math.add(usize, size, chunk_header_size);
        var cells = chunk.cells.valueIterator();
        while (cells.next()) |cell| {
            const slope_size: usize = if (cell.slope != null) 21 else 0;
            const grass_size: usize = if (cell.grass_due != null) 8 else 0;
            size = try std.math.add(usize, size, 3 + slope_size + grass_size);
        }
    }
    if (size > limits.max_bytes) return error.Capacity;
    return size;
}

pub fn encodingScratchBound(state: *const model.State) !usize {
    return std.math.mul(usize, state.by_chunk.count(), @sizeOf(model.Cell));
}

pub const AdmissionBound = struct { size: usize, scratch: usize };

/// A zone can lose cells and acquire timers or slopes without a new admission.
/// Budget the largest wire record each retained material can legally acquire.
pub fn admissionBound(state: *const model.State, bounds: model.Bounds, source: []const model.SourceCell, limits: Limits) !AdmissionBound {
    const records = try std.math.add(usize, state.records.items.len, 1);
    var chunks = state.by_chunk.count();
    var touched = bounds.chunks(state.world_size);
    while (touched.next()) |coords| if (state.chunk(coords) == null) {
        chunks = try std.math.add(u32, chunks, 1);
    };
    var size = try std.math.add(usize, header_size, try std.math.mul(usize, zone_size, records));
    size = try std.math.add(usize, size, try std.math.mul(usize, chunk_header_size, chunks));
    size = try std.math.add(usize, size, try std.math.mul(usize, 3, state.material_counts.occupied));
    size = try std.math.add(usize, size, try std.math.mul(usize, 8, state.material_counts.earth));
    size = try std.math.add(usize, size, try std.math.mul(usize, 21, state.material_counts.adaptive_road));
    for (source) |cell| size = try std.math.add(usize, size, maximumCellSize(cell.value));
    if (size > limits.max_bytes) return error.Capacity;
    return .{ .size = size, .scratch = try std.math.mul(usize, chunks, @sizeOf(model.Cell)) };
}

fn maximumCellSize(cell: model.OwnedCell) usize {
    return 3 + switch (cell.material) {
        .dirt, .grass => @as(usize, 8),
        .custom => @as(usize, 21),
        else => @as(usize, 0),
    };
}

fn chunkLess(_: void, a: model.Cell, b: model.Cell) bool {
    if (a[2] != b[2]) return a[2] < b[2];
    if (a[1] != b[1]) return a[1] < b[1];
    return a[0] < b[0];
}

pub fn encodeState(allocator: std.mem.Allocator, state: *const model.State, limits: Limits) ![]u8 {
    const size = try encodedSize(state, limits);
    if (size == 0) return &.{};
    const chunks = try allocator.alloc(model.Cell, state.by_chunk.count());
    defer allocator.free(chunks);
    var chunk_keys = state.by_chunk.keyIterator();
    var chunk_count: usize = 0;
    while (chunk_keys.next()) |key| {
        if (state.chunk(key.*).?.cells.count() == 0) continue;
        chunks[chunk_count] = key.*;
        chunk_count += 1;
    }
    std.mem.sort(model.Cell, chunks[0..chunk_count], {}, chunkLess);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..magic.len], magic);
    var pos: usize = magic.len;
    format.put(u64, bytes, &pos, state.revision);
    format.put(u32, bytes, &pos, @intCast(state.records.items.len));
    format.put(u32, bytes, &pos, @intCast(chunk_count));
    for (state.records.items) |record| {
        try record.bounds.validate(state.world_size, limits.zone_budgets);
        for (record.bounds.min) |coordinate| format.put(u32, bytes, &pos, coordinate);
        for (record.bounds.size) |count| format.put(u32, bytes, &pos, count);
        format.put(u8, bytes, &pos, @bitCast(record.filter));
    }
    var ordered: [format.cell_count]model.BlockIndex = undefined;
    for (chunks[0..chunk_count]) |coords| {
        const chunk = state.chunk(coords).?;
        for (coords) |coordinate| format.put(u32, bytes, &pos, coordinate);
        const count = chunk.cells.count();
        format.put(u16, bytes, &pos, @intCast(count));
        var keys = chunk.cells.keyIterator();
        var i: usize = 0;
        while (keys.next()) |key| : (i += 1) ordered[i] = key.*;
        std.mem.sort(model.BlockIndex, ordered[0..count], {}, std.sort.asc(model.BlockIndex));
        for (ordered[0..count]) |index| {
            const cell = chunk.cells.get(index).?;
            if (!cell.valid(state.world_size)) return error.InvalidExtractionZone;
            const flags: CellFlags = .{
                .material = if (cell.material == .custom) custom_wire_material else @intCast(@intFromEnum(cell.material)),
                .constructed = cell.constructed,
                .slope = cell.slope != null,
                .grass = cell.grass_due != null,
            };
            format.put(u16, bytes, &pos, index);
            format.put(u8, bytes, &pos, @bitCast(flags));
            if (cell.slope) |slope| {
                for (slope.high_endpoint) |coordinate| format.put(u32, bytes, &pos, coordinate);
                format.put(u8, bytes, &pos, @intCast(@intFromEnum(slope.downhill)));
                format.put(u32, bytes, &pos, slope.length);
                format.put(u32, bytes, &pos, slope.section);
            }
            if (cell.grass_due) |due| format.put(u64, bytes, &pos, due);
        }
    }
    std.debug.assert(pos == bytes.len);
    return bytes;
}

fn readCell(reader: *format.Reader, world_size: model.Cell) !model.OwnedCell {
    const flags: CellFlags = @bitCast(try reader.int(u8));
    const material: u8 = if (flags.material == custom_wire_material) 255 else flags.material;
    if (!format.validBlockMaterial(material)) return error.InvalidExtractionZone;
    var cell: model.OwnedCell = .{ .material = @enumFromInt(material), .constructed = flags.constructed };
    if (flags.slope) {
        var high: model.Cell = undefined;
        for (&high) |*coordinate| coordinate.* = try reader.int(u32);
        const direction = try reader.int(u8);
        if (direction > 3) return error.InvalidExtractionZone;
        cell.slope = .{
            .high_endpoint = high,
            .downhill = @enumFromInt(direction),
            .length = try reader.int(u32),
            .section = try reader.int(u32),
        };
    }
    if (flags.grass) cell.grass_due = try reader.int(u64);
    if (!cell.valid(world_size)) return error.InvalidExtractionZone;
    return cell;
}

/// Parse the wire format once. The storage layer checks framing and field
/// ranges without materializing native cells. Recovery also rebuilds claims
/// and verifies that each occupied cell belongs to exactly one claim.
fn read(allocator: std.mem.Allocator, bytes: []const u8, world_size: model.Cell, limits: Limits, state: ?*model.State) !void {
    if (bytes.len == 0) return;
    if (bytes.len > limits.max_bytes) return error.Capacity;
    var reader: format.Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.InvalidExtractionZone;
    const revision = try reader.int(u64);
    const zone_count = try reader.int(u32);
    const chunk_count = try reader.int(u32);
    if (zone_count == 0 or revision == 0 or
        @as(u64, zone_count) * zone_size + @as(u64, chunk_count) * (chunk_header_size + 3) > bytes.len - header_size) return error.InvalidExtractionZone;
    for (0..zone_count) |_| {
        var bounds: model.Bounds = undefined;
        for (&bounds.min) |*coordinate| coordinate.* = try reader.int(u32);
        for (&bounds.size) |*count| count.* = try reader.int(u32);
        const filter: model.Filter = @bitCast(try reader.int(u8));
        if (!filter.valid()) return error.InvalidExtractionZone;
        if (state) |owned| {
            _ = try owned.register(allocator, bounds, filter, limits.zone_budgets, &.{});
        } else try bounds.validate(world_size, limits.zone_budgets);
    }
    var previous_chunk: ?model.Cell = null;
    for (0..chunk_count) |_| {
        var coords: model.Cell = undefined;
        for (&coords, world_size) |*coordinate, limit| {
            coordinate.* = try reader.int(u32);
            if (coordinate.* >= limit / engine.chunk_utils.CHUNK_SIZE) return error.InvalidExtractionZone;
        }
        if (previous_chunk) |previous| if (!chunkLess({}, previous, coords)) return error.InvalidExtractionZone;
        previous_chunk = coords;
        const count = try reader.int(u16);
        if (count == 0 or count > format.cell_count) return error.InvalidExtractionZone;
        var previous_cell: ?u16 = null;
        for (0..count) |_| {
            const index = try reader.int(u16);
            if (index >= format.cell_count) return error.InvalidExtractionZone;
            if (previous_cell) |previous| if (index <= previous) return error.InvalidExtractionZone;
            previous_cell = index;
            const value = try readCell(&reader, world_size);
            if (state) |owned| try owned.restoreCell(allocator, model.worldCell(coords, @intCast(index)), value);
        }
    }
    try reader.done();
    if (state) |owned| owned.finishRestore(revision);
}

pub fn validate(bytes: []const u8, world_size: model.Cell, limits: Limits) !void {
    try read(std.heap.page_allocator, bytes, world_size, limits, null);
}

pub fn decodeState(allocator: std.mem.Allocator, bytes: []const u8, world_size: model.Cell, limits: Limits) !model.State {
    var state = model.State.init(world_size);
    errdefer state.deinit(allocator);
    try read(allocator, bytes, world_size, limits, &state);
    return state;
}

fn sparseStateRoundtrip(a: std.mem.Allocator) !void {
    const world_size: model.Cell = .{ 128, 128, 128 };
    var state = model.State.init(world_size);
    defer state.deinit(a);
    const bounds: model.Bounds = .{ .min = .{ 127, 31, 7 }, .size = .{ 2, 2, 1 } };
    const road: model.Cell = .{ 127, 31, 7 };
    const mined: model.Cell = .{ 0, 31, 7 };
    const soil: model.Cell = .{ 127, 32, 7 };
    const filter: model.Filter = @bitCast(@as(u8, 0b1001));
    const record = try state.register(a, bounds, filter, .{}, &.{
        .{ .cell = road, .value = .{ .material = .custom, .constructed = true, .slope = .{
            .high_endpoint = .{ 126, 31, 7 },
            .downhill = .positive_x,
            .length = 3,
            .section = 1,
        } } },
        .{ .cell = mined, .value = .{ .material = .stone } },
        .{ .cell = soil, .value = .{ .material = .dirt, .grass_due = 4242 } },
    });
    try std.testing.expect(state.removeCell(mined));
    const wire = try encodeState(a, &state, .{});
    defer a.free(wire);
    try validate(wire, world_size, .{});
    var decoded = try decodeState(a, wire, world_size, .{});
    defer decoded.deinit(a);
    try std.testing.expectEqual(state.revision, decoded.revision);
    try std.testing.expectEqualDeep(record, decoded.recordAt(mined).?);
    try std.testing.expectEqual(null, decoded.cellAt(mined));
    try std.testing.expectEqualDeep(state.cellAt(road), decoded.cellAt(road));
    try std.testing.expectEqualDeep(state.cellAt(soil), decoded.cellAt(soil));
    const soil_chunk = model.cellChunk(soil);
    try std.testing.expect(decoded.grass_chunks.contains(soil_chunk));
    try std.testing.expectEqual(4242, decoded.chunk(soil_chunk).?.timed.events.items[0].due_tick);
    const roundtrip = try encodeState(a, &decoded, .{});
    defer a.free(roundtrip);
    try std.testing.expectEqualSlices(u8, wire, roundtrip);
}

test "extraction zones preserve seam claims protected air road shapes and deadlines through the codec" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sparseStateRoundtrip, .{});
}

test "extraction zone save admission budgets future grass deadlines and formed roads" {
    const a = std.testing.allocator;
    var state = model.State.init(.{ 128, 128, 128 });
    defer state.deinit(a);
    const soil: model.Cell = .{ 10, 10, 10 };
    const road: model.Cell = .{ 11, 10, 10 };
    _ = try state.register(a, .{ .min = soil, .size = .{ 1, 1, 1 } }, .{}, .{}, &.{.{ .cell = soil, .value = .{ .material = .dirt } }});
    const bounds: model.Bounds = .{ .min = road, .size = .{ 1, 1, 1 } };
    const source: []const model.SourceCell = &.{.{ .cell = road, .value = .{ .material = .custom } }};
    const worst_size = header_size + 2 * zone_size + chunk_header_size + 2 * 3 + 8 + 21;
    try std.testing.expectError(error.Capacity, admissionBound(&state, bounds, source, .{ .max_bytes = worst_size - 1 }));
    const bound = try admissionBound(&state, bounds, source, .{ .max_bytes = worst_size });
    try std.testing.expectEqual(worst_size, bound.size);
    _ = try state.register(a, bounds, .{}, .{}, source);
    try state.setGrass(a, soil, 18);
    state.cellPtr(road).?.slope = .{ .high_endpoint = soil, .downhill = .positive_x, .length = 3, .section = 1 };
    state.markCellChanged(road);
    try std.testing.expectEqual(bound.size, try encodedSize(&state, .{ .max_bytes = worst_size }));
}
