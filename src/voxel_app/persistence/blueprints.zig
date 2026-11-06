//! Blueprint records share the world's transaction boundary. Only confirmed
//! definitions and authoritative instance changes enter this module.
const std = @import("std");
const wire = @import("format.zig");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_cells: usize = 1_048_576,
    max_definitions: usize = 4096,
    /// Active sites; final fulfillment releases a slot within the transaction.
    max_instances: usize = 4096,
    max_state_bytes: usize = 64 * 1024 * 1024,
    max_changes_bytes: usize = 16 * 1024 * 1024,
    max_operations: usize = 1_048_576,
};
pub const DefinitionView = struct { id: u64, owner: u64, name: []const u8, size: [3]u32, cells: []const u8, target_count: u32 };
pub const InstanceView = struct { id: u64, definition_id: u64, owner: u64, origin: [3]u32, rotation: u8 };
pub const Fulfill = struct { instance_id: u64, cell_index: u32 };
pub const Op = union(enum) { definition: DefinitionView, instance: InstanceView, fulfill: Fulfill };
/// Allocation-free journal accounting shared by admission and capture. The
/// encoded journal is accounted separately from prepareMemoryBound's scratch.
pub const PrepareSummary = struct {
    operation_count: usize = 0,
    definition_count: usize = 0,
    instance_count: usize = 0,
    fulfillment_count: usize = 0,
    encoded_bytes: usize = 0,
    definition_payload_bytes: usize = 0,
    new_instance_bitmap_bytes: usize = 0,

    /// definition_cells is needed only for a new instance. Other operations
    /// pass zero. Commit the summary only after every checked addition succeeds.
    pub fn addOperation(self: *PrepareSummary, op: Op, definition_cells: usize) !void {
        var next = self.*;
        next.operation_count = try std.math.add(usize, next.operation_count, 1);
        next.encoded_bytes = try std.math.add(usize, next.encoded_bytes, try encodedOpsSize(&.{op}));
        switch (op) {
            .definition => |d| {
                next.definition_count = try std.math.add(usize, next.definition_count, 1);
                next.definition_payload_bytes = try std.math.add(usize, next.definition_payload_bytes, try std.math.add(usize, d.name.len, d.cells.len));
            },
            .instance => {
                next.instance_count = try std.math.add(usize, next.instance_count, 1);
                next.new_instance_bitmap_bytes = try std.math.add(usize, next.new_instance_bitmap_bytes, bitmapLength(definition_cells));
            },
            .fulfill => next.fulfillment_count = try std.math.add(usize, next.fulfillment_count, 1),
        }
        self.* = next;
    }
};

fn bitmapLength(cells: usize) usize {
    return cells / 8 + @intFromBool(cells % 8 != 0);
}

/// Parse operation framing without borrowing State. New-instance bitmap sizes
/// use max_cells, a safe bound when the referenced definition is not available.
/// Capture may supply an exact summary from its already validated journal.
pub fn summarizeEncoded(changes: []const u8, limits: Limits) !PrepareSummary {
    return summarizeFraming(changes, limits, limits.max_cells);
}
fn summarizeFraming(changes: []const u8, limits: Limits, instance_cells: usize) !PrepareSummary {
    if (changes.len > limits.max_changes_bytes) return error.Capacity;
    var result: PrepareSummary = .{};
    var r: wire.Reader = .{ .bytes = changes };
    while (r.pos < changes.len) {
        if (result.operation_count >= limits.max_operations) return error.Capacity;
        const op: Op = switch (try r.int(u8)) {
            1 => .{ .definition = try readDefinition(&r) },
            2 => .{ .instance = try readInstance(&r) },
            3 => .{ .fulfill = .{ .instance_id = try r.int(u64), .cell_index = try r.int(u32) } },
            else => return error.InvalidBlueprint,
        };
        try result.addOperation(op, instance_cells);
    }
    std.debug.assert(result.encoded_bytes == changes.len);
    return result;
}

fn tableCapacity(count: usize) !usize {
    if (count == 0) return 0;
    // Match AutoHashMapUnmanaged's 80% load factor and minimum capacity, with
    // checked arithmetic before its internal u32 sizing assumptions apply.
    const scaled = try std.math.add(usize, try std.math.mul(usize, count, 100) / 80, 1);
    const capacity = @max(@as(usize, 8), try std.math.ceilPowerOfTwo(usize, scaled));
    if (capacity > std.math.maxInt(u32)) return error.Overflow;
    return capacity;
}
fn alignedSize(size: usize, alignment: usize) !usize {
    return (try std.math.add(usize, size, alignment - 1)) & ~(alignment - 1);
}
fn tableBytes(comptime Key: type, comptime Value: type, count: usize) !usize {
    const capacity = try tableCapacity(count);
    if (capacity == 0) return 0;
    const Header = struct { values: [*]Value, keys: [*]Key, capacity: u32 };
    const keys_start = try alignedSize(try std.math.add(usize, @sizeOf(Header), capacity), @alignOf(Key));
    const keys_end = try std.math.add(usize, keys_start, try std.math.mul(usize, capacity, @sizeOf(Key)));
    const values_start = try alignedSize(keys_end, @alignOf(Value));
    const values_end = try std.math.add(usize, values_start, try std.math.mul(usize, capacity, @sizeOf(Value)));
    return alignedSize(values_end, @max(@alignOf(Header), @alignOf(Key), @alignOf(Value)));
}

/// Additional peak allocations for preparation. Existing State payloads and the
/// encoded journal are retained by their owners and charged by capture itself.
/// State hash growth includes old/new table overlap, using the validated active
/// quotas as a baseline so admission never reads the writer's mutable State.
pub fn prepareMemoryBound(summary: PrepareSummary, limits: Limits) !usize {
    var bytes = try std.math.mul(usize, summary.operation_count, @sizeOf(PreparedOp));
    bytes = try std.math.add(usize, bytes, summary.definition_payload_bytes);
    bytes = try std.math.add(usize, bytes, summary.new_instance_bitmap_bytes);
    bytes = try std.math.add(usize, bytes, try std.math.mul(usize, summary.fulfillment_count, @sizeOf(u32)));
    const touched = @min(summary.fulfillment_count, try std.math.add(usize, limits.max_instances, summary.instance_count));
    bytes = try std.math.add(usize, bytes, try tableBytes(u64, TouchedSite, touched));
    bytes = try std.math.add(usize, bytes, try tableBytes(u64, Definition, summary.definition_count));
    bytes = try std.math.add(usize, bytes, try tableBytes(u64, Instance, summary.instance_count));
    if (summary.definition_count != 0) bytes = try std.math.add(usize, bytes, try std.math.mul(usize, 2, try tableBytes(u64, Definition, limits.max_definitions)));
    if (summary.instance_count != 0) bytes = try std.math.add(usize, bytes, try std.math.mul(usize, 2, try tableBytes(u64, Instance, limits.max_instances)));
    return bytes;
}

pub const Definition = struct {
    id: u64,
    owner: u64,
    name: []u8,
    size: [3]u32,
    cells: []u8,
    target_count: u32,
    pub fn view(self: Definition) DefinitionView {
        return .{ .id = self.id, .owner = self.owner, .name = self.name, .size = self.size, .cells = self.cells, .target_count = self.target_count };
    }
    fn deinit(self: *Definition, a: Allocator) void {
        a.free(self.name);
        a.free(self.cells);
    }
};
pub const Instance = struct {
    id: u64,
    definition_id: u64,
    owner: u64,
    origin: [3]u32,
    rotation: u8,
    /// Dense-definition bit index, including zero bits for empty cells.
    fulfilled: []u8,
    remaining: u32,
    pub fn view(self: Instance) InstanceView {
        return .{ .id = self.id, .definition_id = self.definition_id, .owner = self.owner, .origin = self.origin, .rotation = self.rotation };
    }
    pub fn isFulfilled(self: Instance, index: usize) bool {
        return self.fulfilled[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }
    fn mark(self: *Instance, index: usize) void {
        self.fulfilled[index / 8] |= @as(u8, 1) << @intCast(index % 8);
        self.remaining -= 1;
    }
};

/// Returns a borrowed canonical slice. UTF-8 scalar counting is independent of
/// glyph width; duplicate display names remain valid.
pub fn trimmedName(input: []const u8) ![]const u8 {
    return @import("../blueprint_name.zig").checkedName(input) catch error.InvalidBlueprintName;
}
fn validName(name: []const u8) !void {
    if (!std.mem.eql(u8, name, try trimmedName(name))) return error.InvalidBlueprintName;
}
pub fn validMaterial(material: u8) bool {
    return switch (material) {
        0, 2, 5, 8...13 => true,
        else => false,
    };
}
pub fn horizontalLimit(dimensions: [3]u32) !u32 {
    const width = try std.math.mul(u32, dimensions[0], 32);
    const depth = try std.math.mul(u32, dimensions[1], 32);
    if (width < 4) return error.InvalidBlueprint;
    return @min(width / 2 - 1, depth);
}
fn validateDefinition(d: DefinitionView, dimensions: [3]u32, limits: Limits) !void {
    if (d.id == 0) return error.InvalidBlueprint;
    try validName(d.name);
    const limit = try horizontalLimit(dimensions);
    if (d.size[0] == 0 or d.size[1] == 0 or d.size[2] == 0 or d.size[0] > limit or d.size[1] > limit) return error.InvalidBlueprint;
    const volume = try wire.mul(try wire.mul(d.size[0], d.size[1]), d.size[2]);
    if (volume > limits.max_cells or volume != d.cells.len) return error.Capacity;
    var count: u32 = 0;
    var faces = [_]bool{false} ** 6;
    for (d.cells, 0..) |material, i| {
        if (!validMaterial(material)) return error.InvalidBlueprint;
        if (material == 0) continue;
        count = try std.math.add(u32, count, 1);
        const x = i % d.size[0];
        const y = (i / d.size[0]) % d.size[1];
        const z = i / (@as(usize, d.size[0]) * d.size[1]);
        faces[0] = faces[0] or x == 0;
        faces[1] = faces[1] or x == d.size[0] - 1;
        faces[2] = faces[2] or y == 0;
        faces[3] = faces[3] or y == d.size[1] - 1;
        faces[4] = faces[4] or z == 0;
        faces[5] = faces[5] or z == d.size[2] - 1;
    }
    if (count == 0 or count != d.target_count) return error.InvalidBlueprint;
    for (faces) |face| if (!face) return error.InvalidBlueprint;
}
fn copyDefinition(a: Allocator, d: DefinitionView) !Definition {
    const name = try a.dupe(u8, d.name);
    errdefer a.free(name);
    return .{ .id = d.id, .owner = d.owner, .name = name, .size = d.size, .cells = try a.dupe(u8, d.cells), .target_count = d.target_count };
}
fn rotatedSize(d: DefinitionView, rotation: u8) [3]u32 {
    return if (rotation % 2 == 0) d.size else .{ d.size[1], d.size[0], d.size[2] };
}
fn validateInstance(i: InstanceView, d: DefinitionView, dimensions: [3]u32) !void {
    if (i.id == 0 or i.definition_id != d.id or i.owner != d.owner or i.rotation > 3) return error.InvalidBlueprint;
    const size = rotatedSize(d, i.rotation);
    for (dimensions, i.origin, size, 0..) |chunks, origin, extent, axis| {
        const bound = try wire.mul(chunks, 32);
        if (origin >= bound or (axis != 0 and extent > bound - origin)) return error.InvalidBlueprint;
    }
}
fn boxesOverlap(a: InstanceView, ad: DefinitionView, b: InstanceView, bd: DefinitionView, dimensions: [3]u32) bool {
    const as = rotatedSize(ad, a.rotation);
    const bs = rotatedSize(bd, b.rotation);
    for (1..3) |axis| if (@as(u64, a.origin[axis]) + as[axis] <= b.origin[axis] or @as(u64, b.origin[axis]) + bs[axis] <= a.origin[axis]) return false;
    const width = @as(u64, dimensions[0]) * 32;
    const distance = (@as(u64, b.origin[0]) + width - a.origin[0]) % width;
    return distance < as[0] or distance + bs[0] > width;
}
pub fn worldCell(definition: DefinitionView, instance: InstanceView, index: usize, world_width: u32) [3]u32 {
    const x: u32 = @intCast(index % definition.size[0]);
    const y: u32 = @intCast((index / definition.size[0]) % definition.size[1]);
    const z: u32 = @intCast(index / (@as(usize, definition.size[0]) * definition.size[1]));
    const xy: [2]u32 = switch (instance.rotation) {
        0 => .{ x, y },
        1 => .{ y, definition.size[0] - 1 - x },
        2 => .{ definition.size[0] - 1 - x, definition.size[1] - 1 - y },
        3 => .{ definition.size[1] - 1 - y, x },
        else => unreachable,
    };
    return .{ @intCast((@as(u64, instance.origin[0]) + xy[0]) % world_width), instance.origin[1] + xy[1], instance.origin[2] + z };
}

pub const State = struct {
    allocator: Allocator,
    definitions: std.AutoHashMapUnmanaged(u64, Definition) = .empty,
    instances: std.AutoHashMapUnmanaged(u64, Instance) = .empty,
    max_definition_id: u64 = 0,
    max_instance_id: u64 = 0,
    owned_bytes: usize = 0,
    pub fn nextDefinitionId(self: *const State) !u64 {
        return std.math.add(u64, self.max_definition_id, 1) catch error.BlueprintIdExhausted;
    }
    pub fn nextInstanceId(self: *const State) !u64 {
        return std.math.add(u64, self.max_instance_id, 1) catch error.BlueprintIdExhausted;
    }
    pub fn init(a: Allocator) State {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *State) void {
        var defs = self.definitions.valueIterator();
        while (defs.next()) |d| d.deinit(self.allocator);
        var sites = self.instances.valueIterator();
        while (sites.next()) |i| self.allocator.free(i.fulfilled);
        self.definitions.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn clone(self: *const State, a: Allocator) !State {
        var out = State.init(a);
        errdefer out.deinit();
        out.max_definition_id = self.max_definition_id;
        out.max_instance_id = self.max_instance_id;
        out.owned_bytes = self.owned_bytes;
        try out.definitions.ensureTotalCapacity(a, self.definitions.count());
        try out.instances.ensureTotalCapacity(a, self.instances.count());
        var defs = self.definitions.valueIterator();
        while (defs.next()) |d| out.definitions.putAssumeCapacity(d.id, try copyDefinition(a, d.view()));
        var sites = self.instances.valueIterator();
        while (sites.next()) |i| {
            var copy = i.*;
            copy.fulfilled = try a.dupe(u8, i.fulfilled);
            out.instances.putAssumeCapacity(i.id, copy);
        }
        return out;
    }
    /// Caller must establish agreement with real terrain before exposing restored
    /// instances. This includes dirt's approved aging equivalence.
    pub fn validateTerrain(self: *const State, context: anytype, comptime get: anytype, dimensions: [3]u32) !void {
        const width = try std.math.mul(u32, dimensions[0], 32);
        var sites = self.instances.valueIterator();
        while (sites.next()) |instance| {
            const d = self.definitions.get(instance.definition_id) orelse return error.InvalidBlueprint;
            for (d.cells, 0..) |expected, index| {
                if (expected == 0) continue;
                const actual = try get(context, worldCell(d.view(), instance.view(), index, width));
                if (instance.isFulfilled(index)) {
                    if (actual != expected and !(expected == 2 and (actual == 3 or actual == 7))) return error.BlueprintTerrainMismatch;
                } else if (actual != 0) return error.BlueprintTerrainMismatch;
            }
        }
    }
    pub fn prepare(self: *State, changes: []const u8, dimensions: [3]u32, limits: Limits) !Prepared {
        // Replay uses actual definition sizes below, never the conservative
        // capture-only max_cells bound for unknown instance references.
        var summary = try summarizeFraming(changes, limits, 0);
        var out = Prepared.init(self.allocator);
        errdefer out.deinit();
        out.max_definition_id = self.max_definition_id;
        out.max_instance_id = self.max_instance_id;
        out.owned_bytes = self.owned_bytes;
        // Allocate every operation once. Fulfillment-heavy transactions no
        // longer grow 24-byte tagged unions or a u128 hash set per filled cell.
        try out.ops.ensureTotalCapacityPrecise(self.allocator, summary.operation_count);
        _ = try tableCapacity(summary.definition_count);
        _ = try tableCapacity(summary.instance_count);
        try out.definitions.ensureTotalCapacity(self.allocator, @intCast(summary.definition_count));
        try out.instances.ensureTotalCapacity(self.allocator, @intCast(summary.instance_count));
        const touched_bound = @min(summary.fulfillment_count, try std.math.add(usize, self.instances.count(), summary.instance_count));
        _ = try tableCapacity(touched_bound);
        try out.touched.ensureTotalCapacity(self.allocator, @intCast(touched_bound));
        // Count fulfills per site before choosing a dense bitmap or an exact
        // sparse u32 array. Sparse batches never allocate a whole large bitmap.
        var scan: wire.Reader = .{ .bytes = changes };
        while (scan.pos < changes.len) switch (try scan.int(u8)) {
            1 => _ = try readDefinition(&scan),
            2 => _ = try readInstance(&scan),
            3 => {
                const id = try scan.int(u64);
                _ = try scan.int(u32);
                if (out.touched.getPtr(id)) |site| {
                    site.count = try std.math.add(u32, site.count, 1);
                } else {
                    // Invalid IDs must not exhaust an assume-capacity table
                    // before ordered reference validation can reject them.
                    if (out.touched.count() >= touched_bound) return error.InvalidBlueprint;
                    out.touched.putAssumeCapacity(id, .{ .count = 1 });
                }
            },
            else => unreachable,
        };
        // Prepared maps retain completed sites until apply replays their ops.
        // Quotas and final wire size count only sites still active at this point.
        var live_instances: usize = self.instances.count();
        var maximum_live_instances = live_instances;
        var r: wire.Reader = .{ .bytes = changes };
        while (r.pos < r.bytes.len) {
            const kind = try r.int(u8);
            switch (kind) {
                1 => {
                    const view = try readDefinition(&r);
                    try validateDefinition(view, dimensions, limits);
                    if (view.id <= out.max_definition_id or self.definitions.count() + out.definitions.count() >= limits.max_definitions) return error.InvalidBlueprint;
                    out.owned_bytes = try std.math.add(usize, out.owned_bytes, try std.math.add(usize, view.name.len, view.cells.len));
                    if (out.owned_bytes > limits.max_state_bytes) return error.Capacity;
                    const definition = try copyDefinition(self.allocator, view);
                    out.definitions.putAssumeCapacity(view.id, definition);
                    out.max_definition_id = view.id;
                    out.ops.appendAssumeCapacity(.{ .kind = .definition, .id = view.id });
                },
                2 => {
                    const view = try readInstance(&r);
                    const d = out.definitions.get(view.definition_id) orelse self.definitions.get(view.definition_id) orelse return error.InvalidBlueprint;
                    try validateInstance(view, d.view(), dimensions);
                    var existing = self.instances.valueIterator();
                    while (existing.next()) |site| {
                        if (out.remainingFor(site.*) == 0) continue;
                        const other = self.definitions.get(site.definition_id).?;
                        if (boxesOverlap(view, d.view(), site.view(), other.view(), dimensions)) return error.InvalidBlueprint;
                    }
                    existing = out.instances.valueIterator();
                    while (existing.next()) |site| {
                        if (out.remainingFor(site.*) == 0) continue;
                        const other = out.definitions.get(site.definition_id) orelse self.definitions.get(site.definition_id).?;
                        if (boxesOverlap(view, d.view(), site.view(), other.view(), dimensions)) return error.InvalidBlueprint;
                    }
                    if (view.id <= out.max_instance_id or live_instances >= limits.max_instances) return error.InvalidBlueprint;
                    const bit_len = bitmapLength(d.cells.len);
                    summary.new_instance_bitmap_bytes = try std.math.add(usize, summary.new_instance_bitmap_bytes, bit_len);
                    out.owned_bytes = try std.math.add(usize, out.owned_bytes, bit_len);
                    if (out.owned_bytes > limits.max_state_bytes) return error.Capacity;
                    const bits = try self.allocator.alloc(u8, bit_len);
                    @memset(bits, 0);
                    out.instances.putAssumeCapacity(view.id, .{ .id = view.id, .definition_id = view.definition_id, .owner = view.owner, .origin = view.origin, .rotation = view.rotation, .fulfilled = bits, .remaining = d.target_count });
                    out.max_instance_id = view.id;
                    live_instances += 1;
                    maximum_live_instances = @max(maximum_live_instances, live_instances);
                    out.ops.appendAssumeCapacity(.{ .kind = .instance, .id = view.id });
                },
                3 => {
                    const f: Fulfill = .{ .instance_id = try r.int(u64), .cell_index = try r.int(u32) };
                    const instance = out.instances.get(f.instance_id) orelse self.instances.get(f.instance_id) orelse return error.InvalidBlueprint;
                    const d = out.definitions.get(instance.definition_id) orelse self.definitions.get(instance.definition_id) orelse return error.InvalidBlueprint;
                    if (f.cell_index >= d.cells.len or d.cells[f.cell_index] == 0 or instance.isFulfilled(f.cell_index)) return error.InvalidBlueprint;
                    const touched = out.touched.getPtr(f.instance_id).?;
                    if (touched.marks == .none) try touched.start(self.allocator, d.cells.len, instance.remaining);
                    if (touched.remaining == 0) return error.InvalidBlueprint;
                    try touched.mark(f.cell_index);
                    touched.remaining -= 1;
                    if (touched.remaining == 0) {
                        out.owned_bytes -= instance.fulfilled.len;
                        live_instances -= 1;
                    }
                    out.ops.appendAssumeCapacity(.{ .kind = .fulfill, .id = f.instance_id, .cell_index = f.cell_index });
                },
                else => unreachable,
            }
        }
        var touched = out.touched.valueIterator();
        while (touched.next()) |site| try site.checkDuplicates();
        const definition_metadata = try std.math.mul(usize, 38, try std.math.add(usize, self.definitions.count(), out.definitions.count()));
        const instance_metadata = try std.math.mul(usize, 41, live_instances);
        const maximum_encoded = try std.math.add(usize, out.owned_bytes, try std.math.add(usize, 24, try std.math.add(usize, definition_metadata, instance_metadata)));
        if (maximum_encoded > limits.max_state_bytes) return error.Capacity;
        try self.definitions.ensureUnusedCapacity(self.allocator, out.definitions.count());
        // Ordered completion frees slots before replacement creates consume them.
        // Reserving total created sites would retain an arbitrarily oversized map.
        _ = try tableCapacity(maximum_live_instances);
        try self.instances.ensureTotalCapacity(self.allocator, @intCast(maximum_live_instances));
        std.debug.assert(out.ops.items.len == summary.operation_count);
        out.releaseScratch();
        return out;
    }

    /// All allocations and checks occur in prepare, before the WAL commit footer.
    pub fn apply(self: *State, prepared: *Prepared) void {
        for (prepared.ops.items) |op| switch (op.kind) {
            .definition => {
                const d = prepared.definitions.fetchRemove(op.id).?.value;
                self.definitions.putAssumeCapacity(op.id, d);
            },
            .instance => {
                const i = prepared.instances.fetchRemove(op.id).?.value;
                self.instances.putAssumeCapacity(op.id, i);
            },
            .fulfill => {
                const i = self.instances.getPtr(op.id).?;
                i.mark(op.cell_index);
                if (i.remaining == 0) {
                    const removed = self.instances.fetchRemove(op.id).?.value;
                    self.allocator.free(removed.fulfilled);
                }
            },
        };

        self.max_definition_id = prepared.max_definition_id;
        self.max_instance_id = prepared.max_instance_id;
        self.owned_bytes = prepared.owned_bytes;
    }
};
const PreparedOp = extern struct {
    id: u64,
    cell_index: u32 = 0,
    kind: enum(u8) { definition, instance, fulfill },
    reserved: [3]u8 = .{ 0, 0, 0 },
};
const TouchedSite = struct {
    count: u32 = 0,
    used: u32 = 0,
    remaining: u32 = 0,
    marks: union(enum) { none, sparse: []u32, bitmap: []u8 } = .none,

    fn start(self: *TouchedSite, a: Allocator, cells: usize, remaining: u32) !void {
        const dense_bytes = bitmapLength(cells);
        const sparse_bytes = try std.math.mul(usize, self.count, @sizeOf(u32));
        if (dense_bytes <= sparse_bytes) {
            const bits = try a.alloc(u8, dense_bytes);
            @memset(bits, 0);
            self.marks = .{ .bitmap = bits };
        } else {
            self.marks = .{ .sparse = try a.alloc(u32, self.count) };
        }
        self.remaining = remaining;
    }
    fn mark(self: *TouchedSite, index: u32) !void {
        switch (self.marks) {
            .none => unreachable,
            .sparse => |indices| indices[self.used] = index,
            .bitmap => |bits| {
                const mask = @as(u8, 1) << @intCast(index % 8);
                if (bits[index / 8] & mask != 0) return error.InvalidBlueprint;
                bits[index / 8] |= mask;
            },
        }
        self.used += 1;
    }
    fn checkDuplicates(self: *TouchedSite) !void {
        if (self.marks == .sparse) {
            const indices = self.marks.sparse[0..self.used];
            std.mem.sort(u32, indices, {}, std.sort.asc(u32));
            for (indices[1..], indices[0 .. indices.len - 1]) |a, b| if (a == b) return error.InvalidBlueprint;
        }
    }
    fn deinit(self: *TouchedSite, a: Allocator) void {
        switch (self.marks) {
            .none => {},
            .sparse => |indices| a.free(indices),
            .bitmap => |bits| a.free(bits),
        }
    }
};
pub const Prepared = struct {
    allocator: Allocator,
    definitions: std.AutoHashMapUnmanaged(u64, Definition) = .empty,
    instances: std.AutoHashMapUnmanaged(u64, Instance) = .empty,
    touched: std.AutoHashMapUnmanaged(u64, TouchedSite) = .empty,
    ops: std.ArrayList(PreparedOp) = .empty,
    max_definition_id: u64 = 0,
    max_instance_id: u64 = 0,
    owned_bytes: usize = 0,
    fn init(a: Allocator) Prepared {
        return .{ .allocator = a };
    }
    fn remainingFor(self: *const Prepared, instance: Instance) u32 {
        if (self.touched.get(instance.id)) |site| if (site.marks != .none) return site.remaining;
        return instance.remaining;
    }
    fn releaseScratch(self: *Prepared) void {
        var touched = self.touched.valueIterator();
        while (touched.next()) |site| site.deinit(self.allocator);
        self.touched.deinit(self.allocator);
        self.touched = .empty;
    }
    pub fn deinit(self: *Prepared) void {
        var defs = self.definitions.valueIterator();
        while (defs.next()) |d| d.deinit(self.allocator);
        var sites = self.instances.valueIterator();
        while (sites.next()) |i| self.allocator.free(i.fulfilled);
        self.definitions.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.releaseScratch();
        self.ops.deinit(self.allocator);
    }
};

fn appendInt(a: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(a, &bytes);
}
fn writeDefinition(a: Allocator, out: *std.ArrayList(u8), d: DefinitionView) !void {
    try appendInt(a, out, u64, d.id);
    try appendInt(a, out, u64, d.owner);
    try appendInt(a, out, u16, @intCast(d.name.len));
    try out.appendSlice(a, d.name);
    for (d.size) |v| try appendInt(a, out, u32, v);
    try appendInt(a, out, u32, d.target_count);
    try appendInt(a, out, u32, @intCast(d.cells.len));
    try out.appendSlice(a, d.cells);
}
fn readDefinition(r: *wire.Reader) !DefinitionView {
    const id = try r.int(u64);
    const owner = try r.int(u64);
    const name = try r.take(try r.int(u16));
    const size: [3]u32 = .{ try r.int(u32), try r.int(u32), try r.int(u32) };
    const target_count = try r.int(u32);
    const cells = try r.take(try r.int(u32));
    return .{ .id = id, .owner = owner, .name = name, .size = size, .cells = cells, .target_count = target_count };
}
fn writeInstance(a: Allocator, out: *std.ArrayList(u8), i: InstanceView) !void {
    try appendInt(a, out, u64, i.id);
    try appendInt(a, out, u64, i.definition_id);
    try appendInt(a, out, u64, i.owner);
    for (i.origin) |v| try appendInt(a, out, u32, v);
    try appendInt(a, out, u8, i.rotation);
}
fn readInstance(r: *wire.Reader) !InstanceView {
    return .{ .id = try r.int(u64), .definition_id = try r.int(u64), .owner = try r.int(u64), .origin = .{ try r.int(u32), try r.int(u32), try r.int(u32) }, .rotation = try r.int(u8) };
}
pub fn encodedOpsSize(ops: []const Op) !usize {
    var length: usize = 0;
    for (ops) |op| {
        const bytes: usize = switch (op) {
            .definition => |d| blk: {
                try validName(d.name);
                if (d.cells.len > std.math.maxInt(u32)) return error.Capacity;
                break :blk try std.math.add(usize, 39, try std.math.add(usize, d.name.len, d.cells.len));
            },
            .instance => 38,
            .fulfill => 13,
        };
        length = try std.math.add(usize, length, bytes);
    }
    return length;
}

pub fn encodeOps(a: Allocator, ops: []const Op) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const size = try encodedOpsSize(ops);
    try out.ensureTotalCapacityPrecise(a, size);
    for (ops) |op| switch (op) {
        .definition => |d| {
            try out.append(a, 1);
            try writeDefinition(a, &out, d);
        },
        .instance => |i| {
            try out.append(a, 2);
            try writeInstance(a, &out, i);
        },
        .fulfill => |f| {
            try out.append(a, 3);
            try appendInt(a, &out, u64, f.instance_id);
            try appendInt(a, &out, u32, f.cell_index);
        },
    };
    std.debug.assert(out.items.len == size);
    return out.toOwnedSlice(a);
}

/// The initial chain-discovery pass has no predecessor gameplay state yet.
/// Validate complete operation framing here; reference/progress checks run when
/// the selected committed chain is replayed in order.
pub fn validateOps(bytes: []const u8, dimensions: [3]u32, limits: Limits) !void {
    if (bytes.len > limits.max_changes_bytes) return error.Capacity;
    var r: wire.Reader = .{ .bytes = bytes };
    while (r.pos < bytes.len) switch (try r.int(u8)) {
        1 => try validateDefinition(try readDefinition(&r), dimensions, limits),
        2 => {
            const instance = try readInstance(&r);
            if (instance.id == 0 or instance.definition_id == 0 or instance.rotation > 3) return error.InvalidBlueprint;
        },
        3 => {
            if (try r.int(u64) == 0) return error.InvalidBlueprint;
            _ = try r.int(u32);
        },
        else => return error.InvalidBlueprint,
    };
}

pub fn encodeState(a: Allocator, state: *const State) ![]u8 {
    if (state.max_definition_id == 0 and state.max_instance_id == 0 and state.definitions.count() == 0 and state.instances.count() == 0) return a.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendInt(a, &out, u64, state.max_definition_id);
    try appendInt(a, &out, u64, state.max_instance_id);
    try appendInt(a, &out, u32, state.definitions.count());
    try appendInt(a, &out, u32, state.instances.count());
    const ids = try a.alloc(u64, @max(state.definitions.count(), state.instances.count()));
    defer a.free(ids);
    var keys = state.definitions.keyIterator();
    var n: usize = 0;
    while (keys.next()) |id| : (n += 1) ids[n] = id.*;
    std.mem.sort(u64, ids[0..n], {}, std.sort.asc(u64));
    for (ids[0..n]) |id| try writeDefinition(a, &out, state.definitions.get(id).?.view());
    var instance_keys = state.instances.keyIterator();
    n = 0;
    while (instance_keys.next()) |id| : (n += 1) ids[n] = id.*;
    std.mem.sort(u64, ids[0..n], {}, std.sort.asc(u64));
    for (ids[0..n]) |id| {
        const i = state.instances.get(id).?;
        try writeInstance(a, &out, i.view());
        try appendInt(a, &out, u32, i.remaining);
        try out.appendSlice(a, i.fulfilled);
    }
    return out.toOwnedSlice(a);
}
pub fn decodeState(a: Allocator, bytes: []const u8, dimensions: [3]u32, limits: Limits) !State {
    if (bytes.len > limits.max_state_bytes) return error.Capacity;
    var state = State.init(a);
    errdefer state.deinit();
    if (bytes.len == 0) return state;
    var r: wire.Reader = .{ .bytes = bytes };
    state.max_definition_id = try r.int(u64);
    state.max_instance_id = try r.int(u64);
    const dc = try r.int(u32);
    const ic = try r.int(u32);
    if (state.max_definition_id == 0 and state.max_instance_id == 0 and dc == 0 and ic == 0) return error.InvalidBlueprint;
    if (dc > limits.max_definitions or ic > limits.max_instances) return error.Capacity;
    try state.definitions.ensureTotalCapacity(a, dc);
    try state.instances.ensureTotalCapacity(a, ic);
    var previous: u64 = 0;
    for (0..dc) |_| {
        const d = try readDefinition(&r);
        try validateDefinition(d, dimensions, limits);
        if (d.id <= previous or d.id > state.max_definition_id) return error.InvalidBlueprint;
        previous = d.id;
        state.definitions.putAssumeCapacity(d.id, try copyDefinition(a, d));
        state.owned_bytes = try std.math.add(usize, state.owned_bytes, d.name.len + d.cells.len);
    }
    previous = 0;
    for (0..ic) |_| {
        const i = try readInstance(&r);
        const d = state.definitions.get(i.definition_id) orelse return error.InvalidBlueprint;
        try validateInstance(i, d.view(), dimensions);
        var existing = state.instances.valueIterator();
        while (existing.next()) |site| if (boxesOverlap(i, d.view(), site.view(), state.definitions.get(site.definition_id).?.view(), dimensions)) return error.InvalidBlueprint;
        if (i.id <= previous or i.id > state.max_instance_id) return error.InvalidBlueprint;
        previous = i.id;
        const remaining = try r.int(u32);
        const bits = try r.take((d.cells.len + 7) / 8);
        var actual: u32 = d.target_count;
        for (d.cells, 0..) |material, index| if (bits[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0) {
            if (material == 0) return error.InvalidBlueprint;
            actual -= 1;
        };
        if (remaining == 0 or remaining != actual) return error.InvalidBlueprint;
        if (d.cells.len % 8 != 0 and bits[bits.len - 1] >> @as(u3, @intCast(d.cells.len % 8)) != 0) return error.InvalidBlueprint;
        state.instances.putAssumeCapacity(i.id, .{ .id = i.id, .definition_id = i.definition_id, .owner = i.owner, .origin = i.origin, .rotation = i.rotation, .remaining = remaining, .fulfilled = try a.dupe(u8, bits) });
        state.owned_bytes = try std.math.add(usize, state.owned_bytes, bits.len);
    }
    try r.done();
    if (state.owned_bytes > limits.max_state_bytes) return error.Capacity;
    return state;
}

test "names count Unicode scalars and trim Unicode whitespace" {
    try std.testing.expectEqualStrings("城", try trimmedName("\xe3\x80\x80城\xc2\xa0"));
    try std.testing.expectError(error.InvalidBlueprintName, trimmedName(" \t"));
    try std.testing.expectError(error.InvalidBlueprintName, trimmedName("a\nb"));
    try std.testing.expectError(error.InvalidBlueprintName, trimmedName("\xff"));
    try std.testing.expectError(error.InvalidBlueprintName, trimmedName("a" ** 101));
}
test "incremental fulfillment preflight is atomic, checkpoints retain progress and retired ID" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    const def: DefinitionView = .{ .id = 1, .owner = 9, .name = "Beam", .size = .{ 3, 1, 1 }, .cells = &.{ 10, 10, 10 }, .target_count = 3 };
    const changes = try encodeOps(a, &.{ .{ .definition = def }, .{ .instance = .{ .id = 8, .definition_id = 1, .owner = 9, .origin = .{ 127, 1, 5 }, .rotation = 0 } }, .{ .fulfill = .{ .instance_id = 8, .cell_index = 0 } } });
    defer a.free(changes);
    var prepared = try state.prepare(changes, dimensions, .{});
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u32, 0), state.definitions.count());
    state.apply(&prepared);
    const encoded = try encodeState(a, &state);
    defer a.free(encoded);
    var restored = try decodeState(a, encoded, dimensions, .{});
    defer restored.deinit();
    try std.testing.expect(restored.instances.get(8).?.isFulfilled(0));
    try std.testing.expectEqual(@as(u32, 2), restored.instances.get(8).?.remaining);
    const delta = try encodeOps(a, &.{ .{ .fulfill = .{ .instance_id = 8, .cell_index = 1 } }, .{ .fulfill = .{ .instance_id = 8, .cell_index = 2 } } });
    defer a.free(delta);
    try std.testing.expectEqual(@as(usize, 26), delta.len);
    var final = try restored.prepare(delta, dimensions, .{});
    defer final.deinit();
    restored.apply(&final);
    try std.testing.expectEqual(@as(u32, 0), restored.instances.count());
    try std.testing.expectEqual(@as(u64, 8), restored.max_instance_id);
    try std.testing.expectEqual(@as(u32, 1), restored.definitions.count());
}

fn completedSiteQuotaScenario(a: Allocator, persisted: bool) !void {
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    const definition: Op = .{ .definition = .{ .id = 1, .owner = 9, .name = "Beam", .size = .{ 2, 1, 1 }, .cells = &.{ 10, 10 }, .target_count = 2 } };
    const first: Op = .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 9, .origin = .{ 1, 1, 5 }, .rotation = 0 } };
    const replacement: Op = .{ .instance = .{ .id = 2, .definition_id = 1, .owner = 9, .origin = .{ 4, 1, 5 }, .rotation = 0 } };
    const fill_first: Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } };
    const fill_last: Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 1 } };
    // Exactly one definition and one active site's bitmap and wire metadata fit.
    const final_size = 24 + 38 + definition.definition.name.len + definition.definition.cells.len + 41 + 1;
    const limits: Limits = .{ .max_instances = 1, .max_state_bytes = final_size };
    const initial = try encodeOps(a, if (persisted) &.{ definition, first, fill_first } else &.{definition});
    defer a.free(initial);
    var seed = try state.prepare(initial, dimensions, limits);
    defer seed.deinit();
    state.apply(&seed);
    const before = try encodeState(a, &state);
    defer a.free(before);
    const changes = try encodeOps(a, if (persisted) &.{ fill_last, replacement } else &.{ first, fill_first, fill_last, replacement });
    defer a.free(changes);
    var prepared = try state.prepare(changes, dimensions, limits);
    defer prepared.deinit();
    const uncommitted = try encodeState(a, &state);
    defer a.free(uncommitted);
    try std.testing.expectEqualSlices(u8, before, uncommitted);
    state.apply(&prepared);
    try std.testing.expectEqual(@as(u32, 1), state.instances.count());
    try std.testing.expect(!state.instances.contains(1));
    try std.testing.expectEqual(@as(u32, 2), state.instances.get(2).?.remaining);
    try std.testing.expectEqual(@as(u64, 2), state.max_instance_id);
    try std.testing.expectEqual(definition.definition.name.len + definition.definition.cells.len + 1, state.owned_bytes);
    const encoded = try encodeState(a, &state);
    defer a.free(encoded);
    try std.testing.expectEqual(final_size, encoded.len);
    var restored = try decodeState(a, encoded, dimensions, limits);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u32, 1), restored.instances.count());
    try std.testing.expectEqual(@as(u64, 2), restored.max_instance_id);
    try std.testing.expectEqual(@as(u32, 2), restored.instances.get(2).?.remaining);
}

test "persisted completion releases transaction instance quota and encoded metadata" {
    try completedSiteQuotaScenario(std.testing.allocator, true);
}

test "same-batch completion releases transaction instance quota and encoded metadata" {
    try completedSiteQuotaScenario(std.testing.allocator, false);
}

test "instance quota remains enforced until final fulfillment without publishing failed changes" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    const limits: Limits = .{ .max_instances = 1 };
    const first: Op = .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 9, .origin = .{ 1, 1, 5 }, .rotation = 0 } };
    const replacement: Op = .{ .instance = .{ .id = 2, .definition_id = 1, .owner = 9, .origin = .{ 4, 1, 5 }, .rotation = 0 } };
    const fill_first: Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } };
    const fill_last: Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 1 } };
    const initial = try encodeOps(a, &.{ .{ .definition = .{ .id = 1, .owner = 9, .name = "Beam", .size = .{ 2, 1, 1 }, .cells = &.{ 10, 10 }, .target_count = 2 } }, first });
    defer a.free(initial);
    var seed = try state.prepare(initial, dimensions, limits);
    defer seed.deinit();
    state.apply(&seed);
    const before = try encodeState(a, &state);
    defer a.free(before);
    for ([_][]const Op{ &.{replacement}, &.{ fill_first, replacement }, &.{ replacement, fill_first, fill_last }, &.{ fill_first, fill_last, replacement, fill_last } }) |ops| {
        const changes = try encodeOps(a, ops);
        defer a.free(changes);
        try std.testing.expectError(error.InvalidBlueprint, state.prepare(changes, dimensions, limits));
        const after = try encodeState(a, &state);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }
}

fn allocationScenario(a: Allocator) !void {
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    const definition: DefinitionView = .{ .id = 1, .owner = 7, .name = "House", .size = .{ 2, 1, 1 }, .cells = &.{ 2, 10 }, .target_count = 2 };
    const changes = try encodeOps(a, &.{ .{ .definition = definition }, .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 7, .origin = .{ 127, 2, 3 }, .rotation = 0 } }, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } } });
    defer a.free(changes);
    var prepared = try state.prepare(changes, dimensions, .{});
    defer prepared.deinit();
    state.apply(&prepared);
    var frozen = try state.clone(a);
    defer frozen.deinit();
    const bytes = try encodeState(a, &frozen);
    defer a.free(bytes);
    var decoded = try decodeState(a, bytes, dimensions, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 1), decoded.instances.get(1).?.remaining);
}
test "blueprint transaction and checkpoint allocation failures release ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "malformed progress cannot publish and decode rejects corrupt bitmaps and overlapping sites" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    const definition: DefinitionView = .{ .id = 1, .owner = 7, .name = "Cavity", .size = .{ 3, 1, 1 }, .cells = &.{ 2, 0, 10 }, .target_count = 2 };
    const initial = try encodeOps(a, &.{ .{ .definition = definition }, .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 7, .origin = .{ 127, 2, 3 }, .rotation = 0 } } });
    defer a.free(initial);
    var prepared = try state.prepare(initial, dimensions, .{});
    defer prepared.deinit();
    state.apply(&prepared);
    const invalid = try encodeOps(a, &.{ .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } }, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } } });
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidBlueprint, state.prepare(invalid, dimensions, .{}));
    try std.testing.expectEqual(@as(u32, 2), state.instances.get(1).?.remaining);
    const empty = try encodeOps(a, &.{.{ .fulfill = .{ .instance_id = 1, .cell_index = 1 } }});
    defer a.free(empty);
    try std.testing.expectError(error.InvalidBlueprint, state.prepare(empty, dimensions, .{}));
    const overlap = try encodeOps(a, &.{.{ .instance = .{ .id = 2, .definition_id = 1, .owner = 7, .origin = .{ 0, 2, 3 }, .rotation = 0 } }});
    defer a.free(overlap);
    try std.testing.expectError(error.InvalidBlueprint, state.prepare(overlap, dimensions, .{}));
    const foreign = try encodeOps(a, &.{.{ .instance = .{ .id = 2, .definition_id = 1, .owner = 8, .origin = .{ 10, 2, 3 }, .rotation = 0 } }});
    defer a.free(foreign);
    try std.testing.expectError(error.InvalidBlueprint, state.prepare(foreign, dimensions, .{}));
    const encoded = try encodeState(a, &state);
    defer a.free(encoded);
    for (1..encoded.len) |cut| try std.testing.expectError(error.InvalidFormat, decodeState(a, encoded[0..cut], dimensions, .{}));
    encoded[encoded.len - 1] = 0b10;
    try std.testing.expectError(error.InvalidBlueprint, decodeState(a, encoded, dimensions, .{}));
    encoded[encoded.len - 1] = 0x80;
    try std.testing.expectError(error.InvalidBlueprint, decodeState(a, encoded, dimensions, .{}));
    state.max_instance_id = std.math.maxInt(u64);
    try std.testing.expectError(error.BlueprintIdExhausted, state.nextInstanceId());
}

test "restored progress requires real terrain agreement including dirt aging and seam rotation" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    const changes = try encodeOps(a, &.{ .{ .definition = .{ .id = 1, .owner = 7, .name = "Soil", .size = .{ 1, 2, 1 }, .cells = &.{ 2, 2 }, .target_count = 2 } }, .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 7, .origin = .{ 127, 2, 3 }, .rotation = 1 } }, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } } });
    defer a.free(changes);
    var prepared = try state.prepare(changes, dimensions, .{});
    defer prepared.deinit();
    state.apply(&prepared);
    const Terrain = struct {
        actual: u8 = 3,
        pending: u8 = 0,
        fn get(self: @This(), cell: [3]u32) !u8 {
            if (cell[1] != 2 or cell[2] != 3) return error.BadTestCoordinate;
            return if (cell[0] == 127) self.actual else if (cell[0] == 0) self.pending else error.BadTestCoordinate;
        }
    };
    try state.validateTerrain(Terrain{}, Terrain.get, dimensions);
    try state.validateTerrain(Terrain{ .actual = 7 }, Terrain.get, dimensions);
    try std.testing.expectError(error.BlueprintTerrainMismatch, state.validateTerrain(Terrain{ .actual = 10 }, Terrain.get, dimensions));
    try std.testing.expectError(error.BlueprintTerrainMismatch, state.validateTerrain(Terrain{ .pending = 2 }, Terrain.get, dimensions));
}

test "prepare summary matches encoded journal and charges bounded scratch" {
    const a = std.testing.allocator;
    const definition: Op = .{ .definition = .{ .id = 1, .owner = 7, .name = "Accounting", .size = .{ 3, 1, 1 }, .cells = &.{ 10, 0, 10 }, .target_count = 2 } };
    const instance: Op = .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 7, .origin = .{ 1, 1, 1 }, .rotation = 0 } };
    const fulfillment: Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } };
    var exact: PrepareSummary = .{};
    try exact.addOperation(definition, 0);
    try exact.addOperation(instance, definition.definition.cells.len);
    try exact.addOperation(fulfillment, 0);
    const encoded = try encodeOps(a, &.{ definition, instance, fulfillment });
    defer a.free(encoded);
    const parsed = try summarizeEncoded(encoded, .{ .max_cells = 3 });
    try std.testing.expectEqualDeep(exact, parsed);
    try std.testing.expectEqual(encoded.len, exact.encoded_bytes);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PreparedOp));
    try std.testing.expectEqual(@as(usize, 1), exact.new_instance_bitmap_bytes);
    try std.testing.expectEqual(@as(usize, 13), exact.definition_payload_bytes);
    try std.testing.expectEqual(@as(usize, 0), try prepareMemoryBound(.{}, .{}));
    try std.testing.expect((try prepareMemoryBound(exact, .{})) > exact.definition_payload_bytes);
    try std.testing.expectError(error.Capacity, summarizeEncoded(encoded, .{ .max_operations = 2 }));
    try std.testing.expectError(error.Capacity, summarizeEncoded(encoded, .{ .max_changes_bytes = encoded.len - 1 }));
    try std.testing.expectError(error.InvalidFormat, summarizeEncoded(encoded[0 .. encoded.len - 1], .{}));
}

test "prepare summary overflow cannot partially mutate admission accounting" {
    var summary: PrepareSummary = .{ .encoded_bytes = std.math.maxInt(usize) };
    const before = summary;
    try std.testing.expectError(error.Overflow, summary.addOperation(.{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } }, 0));
    try std.testing.expectEqualDeep(before, summary);
    try std.testing.expectError(error.Overflow, prepareMemoryBound(.{ .operation_count = std.math.maxInt(usize) }, .{}));
    try std.testing.expectError(error.Overflow, prepareMemoryBound(.{ .fulfillment_count = std.math.maxInt(usize) }, .{}));
    try std.testing.expectError(error.Overflow, prepareMemoryBound(.{ .instance_count = 1 }, .{ .max_instances = std.math.maxInt(usize) }));
}

test "malformed fulfillment IDs cannot exhaust bounded scratch maps" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const invalid = try encodeOps(a, &.{.{ .fulfill = .{ .instance_id = 99, .cell_index = 0 } }});
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidBlueprint, state.prepare(invalid, .{ 4, 4, 4 }, .{}));
    try std.testing.expectEqual(@as(u32, 0), state.instances.count());
}

test "ordered replacement reserves live State slots instead of total created sites" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    var journal: std.ArrayList(Op) = .empty;
    defer journal.deinit(a);
    try journal.append(a, .{ .definition = .{ .id = 1, .owner = 1, .name = "Replacement", .size = .{ 1, 1, 1 }, .cells = &.{10}, .target_count = 1 } });
    for (1..65) |id| {
        try journal.append(a, .{ .instance = .{ .id = id, .definition_id = 1, .owner = 1, .origin = .{ 1, 1, 1 }, .rotation = 0 } });
        try journal.append(a, .{ .fulfill = .{ .instance_id = id, .cell_index = 0 } });
    }
    const changes = try encodeOps(a, journal.items);
    defer a.free(changes);
    var prepared = try state.prepare(changes, dimensions, .{ .max_instances = 1 });
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u32, 8), state.instances.capacity());
    state.apply(&prepared);
    try std.testing.expectEqual(@as(u32, 0), state.instances.count());
    try std.testing.expectEqual(@as(u64, 64), state.max_instance_id);
    try std.testing.expectEqual(@as(u32, 8), state.instances.capacity());
}

test "replay preparation uses actual bitmap sizes instead of capture fallback bounds" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const dimensions: [3]u32 = .{ 4, 4, 4 };
    var journal: std.ArrayList(Op) = .empty;
    defer journal.deinit(a);
    try journal.append(a, .{ .definition = .{ .id = 1, .owner = 1, .name = "Replay", .size = .{ 1, 1, 1 }, .cells = &.{10}, .target_count = 1 } });
    for (1..17) |id| {
        try journal.append(a, .{ .instance = .{ .id = id, .definition_id = 1, .owner = 1, .origin = .{ 1, 1, 1 }, .rotation = 0 } });
        try journal.append(a, .{ .fulfill = .{ .instance_id = id, .cell_index = 0 } });
    }
    const changes = try encodeOps(a, journal.items);
    defer a.free(changes);
    const limits: Limits = .{ .max_instances = 1, .max_cells = std.math.maxInt(usize) };
    // The stateless capture fallback cannot know that these are one-byte maps.
    try std.testing.expectError(error.Overflow, summarizeEncoded(changes, limits));
    var prepared = try state.prepare(changes, dimensions, limits);
    defer prepared.deinit();
    state.apply(&prepared);
    try std.testing.expectEqual(@as(u32, 0), state.instances.count());
    try std.testing.expectEqual(@as(u64, 16), state.max_instance_id);
}
