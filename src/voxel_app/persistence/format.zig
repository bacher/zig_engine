//! Versioned wire codecs. All wire storage is bytes, never native struct layout.
const std = @import("std");
pub const current_write_version: u32 = 2;
pub const minimum_readable_version: u32 = 1;
pub const Uuid = [16]u8;
pub const Digest = [32]u8;
pub const cell_count = 32768;
pub const maximum_metadata_size = 1179675;
pub const maximum_chunk_size = 1212501;
pub const Error = error{ InvalidFormat, UnsupportedVersion, UnsupportedCodec, InvalidMetadata, InvalidDescriptor, ChecksumMismatch, Overflow };
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    pub fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.pos) return error.InvalidFormat;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }
    pub fn int(self: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    pub fn done(self: Reader) Error!void {
        if (self.pos != self.bytes.len) return error.InvalidFormat;
    }
};
pub fn put(comptime T: type, bytes: []u8, pos: *usize, value: T) void {
    std.mem.writeInt(T, bytes[pos.*..][0..@sizeOf(T)], value, .little);
    pos.* += @sizeOf(T);
}
pub fn hash(domain: []const u8, parts: []const []const u8) Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(domain);
    for (parts) |part| h.update(part);
    var out: Digest = undefined;
    h.final(&out);
    return out;
}
pub fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.Overflow;
}
pub fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.Overflow;
}
pub fn native(n: u64) Error!usize {
    return std.math.cast(usize, n) orelse error.Overflow;
}
pub fn range(offset: u64, len: u64, size: u64) Error!void {
    if (offset > size or len > size - offset) return error.InvalidFormat;
}

pub const ChunkView = struct { id: u32, revision: u64, is_unreachable: bool, blocks: []const u8, metadata: []const u8 };
pub const Chunk = struct {
    id: u32,
    revision: u64,
    is_unreachable: bool,
    blocks: []u8,
    metadata: []u8,
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.blocks);
        allocator.free(self.metadata);
        self.* = undefined;
    }
    pub fn view(self: Chunk) ChunkView {
        return .{ .id = self.id, .revision = self.revision, .is_unreachable = self.is_unreachable, .blocks = self.blocks, .metadata = self.metadata };
    }
};

pub fn validateMetadata(blocks: []const u8, metadata: []const u8, dimensions: [3]u32) Error!void {
    if (blocks.len != cell_count or metadata.len > maximum_metadata_size) return error.InvalidMetadata;
    var custom_count: usize = 0;
    for (blocks) |b| {
        if (b == 255) custom_count += 1;
    }
    var found_custom = false;
    var previous: u16 = 0;
    var r: Reader = .{ .bytes = metadata };
    while (r.pos < metadata.len) {
        const kind = try r.int(u16);
        const schema = try r.int(u16);
        const flags = try r.int(u8);
        const length = try r.int(u32);
        if (kind == 0 or kind <= previous or flags != 1 or schema != 1 or kind > 3 or length == 0) return error.InvalidMetadata;
        previous = kind;
        var payload: Reader = .{ .bytes = try r.take(length) };
        switch (kind) {
            1 => {
                found_custom = true;
                if (length > 753664) return error.InvalidMetadata;
                for (0..custom_count) |_| {
                    if (try payload.int(u8) != 0) return error.InvalidMetadata;
                    switch (try payload.int(u8)) {
                        0 => {},
                        1 => {
                            for (dimensions) |dim| {
                                const high = try payload.int(u32);
                                if (@as(u64, high) >= @as(u64, dim) * 32) return error.InvalidMetadata;
                            }
                            if (try payload.int(u8) > 3) return error.InvalidMetadata;
                            const len = try payload.int(u32);
                            const section = try payload.int(u32);
                            if (len == 0 or section >= len) return error.InvalidMetadata;
                        },
                        else => return error.InvalidMetadata,
                    }
                }
            },
            2, 3 => {
                const stride: usize = if (kind == 2) 2 else 11;
                if (length % stride != 0 or length / stride > cell_count) return error.InvalidMetadata;
                var seen = [_]bool{false} ** cell_count;
                for (0..length / stride) |_| {
                    const index = try payload.int(u16);
                    if (index >= cell_count or seen[index]) return error.InvalidMetadata;
                    seen[index] = true;
                    if (kind == 3) {
                        if (try payload.int(u8) > 1) return error.InvalidMetadata;
                        _ = try payload.int(u64);
                    }
                }
            },
            else => unreachable,
        }
        try payload.done();
    }
    if (custom_count != 0 and !found_custom) return error.InvalidMetadata;
}

const ChunkParts = struct { id: u32, revision: u64, flags: u8, codec: u8, payload: []const u8, metadata: []const u8 };
fn chunkParts(uuid: Uuid, bytes: []const u8) Error!ChunkParts {
    if (bytes.len < 58 or bytes.len > maximum_chunk_size) return error.InvalidFormat;
    var r: Reader = .{ .bytes = bytes };
    if (try r.int(u32) != bytes.len) return error.InvalidFormat;
    const id = try r.int(u32);
    const revision = try r.int(u64);
    const flags = try r.int(u8);
    const codec = try r.int(u8);
    if (flags & 0xfe != 0) return error.InvalidFormat;
    if (codec > 1) return error.UnsupportedCodec;
    const length = try r.int(u32);
    if (length > cell_count) return error.InvalidFormat;
    const payload = try r.take(length);
    const metadata_len = try r.int(u32);
    if (metadata_len > maximum_metadata_size) return error.InvalidMetadata;
    const metadata = try r.take(metadata_len);
    const checksum = try r.take(32);
    try r.done();
    const expected = hash("ZGW-CHUNK-1\x00", &.{ &uuid, bytes[0 .. bytes.len - 32] });
    if (!std.mem.eql(u8, &expected, checksum)) return error.ChecksumMismatch;
    return .{ .id = id, .revision = revision, .flags = flags, .codec = codec, .payload = payload, .metadata = metadata };
}
fn validateChunkId(id: u32, dimensions: [3]u32) Error!void {
    const count = try mul(try mul(dimensions[0], dimensions[1]), dimensions[2]);
    if (@as(u64, id) >= count) return error.InvalidFormat;
}
fn expand(parts: ChunkParts, out: []u8) Error!void {
    if (parts.codec == 0) {
        if (parts.payload.len != cell_count) return error.InvalidFormat;
        @memcpy(out, parts.payload);
        return;
    }
    if (parts.payload.len % 2 != 0) return error.InvalidFormat;
    @memset(out, 0);
    var pos: usize = 0;
    var r: Reader = .{ .bytes = parts.payload };
    while (r.pos < r.bytes.len) {
        const value = try r.int(u8);
        const count = try r.int(u8);
        if (count == 0 or count > cell_count - pos) return error.InvalidFormat;
        @memset(out[pos..][0..count], value);
        pos += count;
    }
}
pub fn validateChunkRecord(uuid: Uuid, bytes: []const u8, dimensions: [3]u32) Error!void {
    const parts = try chunkParts(uuid, bytes);
    try validateChunkId(parts.id, dimensions);
    var blocks: [cell_count]u8 = undefined;
    try expand(parts, &blocks);
    try validateMetadata(&blocks, parts.metadata, dimensions);
}
pub fn decodeChunk(allocator: std.mem.Allocator, uuid: Uuid, bytes: []const u8, dimensions: [3]u32) !Chunk {
    const parts = try chunkParts(uuid, bytes);
    try validateChunkId(parts.id, dimensions);
    const blocks = try allocator.alloc(u8, cell_count);
    errdefer allocator.free(blocks);
    try expand(parts, blocks);
    try validateMetadata(blocks, parts.metadata, dimensions);
    const metadata = try allocator.dupe(u8, parts.metadata);
    return .{ .id = parts.id, .revision = parts.revision, .is_unreachable = parts.flags == 1, .blocks = blocks, .metadata = metadata };
}
pub fn encodeChunk(allocator: std.mem.Allocator, uuid: Uuid, chunk: ChunkView) ![]u8 {
    // Endpoint bounds are validated against the saved layout at the container boundary.
    try validateMetadata(chunk.blocks, chunk.metadata, .{ 134217728, 134217728, 134217728 });
    var scratch: [cell_count]u8 = undefined;
    var length: usize = 0;
    var end = chunk.blocks.len;
    while (end > 0 and chunk.blocks[end - 1] == 0) : (end -= 1) {}
    var i: usize = 0;
    var codec: u8 = 1;
    while (i < end) {
        const value = chunk.blocks[i];
        var count: usize = 1;
        while (count < 255 and i + count < end and chunk.blocks[i + count] == value) : (count += 1) {}
        if (length + 2 > cell_count) {
            codec = 0;
            break;
        }
        scratch[length] = value;
        scratch[length + 1] = @intCast(count);
        length += 2;
        i += count;
    }
    const payload = if (codec == 0) chunk.blocks else scratch[0..length];
    const out = try allocator.alloc(u8, 58 + payload.len + chunk.metadata.len);
    errdefer allocator.free(out);
    var p: usize = 0;
    put(u32, out, &p, @intCast(out.len));
    put(u32, out, &p, chunk.id);
    put(u64, out, &p, chunk.revision);
    put(u8, out, &p, @intFromBool(chunk.is_unreachable));
    put(u8, out, &p, codec);
    put(u32, out, &p, @intCast(payload.len));
    @memcpy(out[p..][0..payload.len], payload);
    p += payload.len;
    put(u32, out, &p, @intCast(chunk.metadata.len));
    @memcpy(out[p..][0..chunk.metadata.len], chunk.metadata);
    p += chunk.metadata.len;
    const checksum = hash("ZGW-CHUNK-1\x00", &.{ &uuid, out[0..p] });
    @memcpy(out[p..], &checksum);
    return out;
}

pub fn encodeGlobal(tick: u64) [10]u8 {
    var out: [10]u8 = undefined;
    var p: usize = 0;
    put(u16, &out, &p, 1);
    put(u64, &out, &p, tick);
    return out;
}
pub fn decodeGlobal(bytes: []const u8) Error!u64 {
    var r: Reader = .{ .bytes = bytes };
    if (try r.int(u16) != 1) return error.UnsupportedVersion;
    const tick = try r.int(u64);
    try r.done();
    return tick;
}
pub const player_record_size = 53;
pub const Player = struct { id: u64, feet: [3]f64, yaw: f32, pitch: f32, inventory: ?u8 = null };
fn validatePlayer(player: Player) Error!void {
    for (player.feet) |v| {
        if (!std.math.isFinite(v)) return error.InvalidFormat;
    }
    if (!std.math.isFinite(player.yaw) or !std.math.isFinite(player.pitch)) return error.InvalidFormat;
    // Persist only placeable inventory materials, including the adaptive-road item.
    if (player.inventory) |material| switch (material) {
        2, 4, 5, 6, 8...14 => {},
        else => return error.InvalidFormat,
    };
}
pub fn encodePlayer(player: Player) Error![player_record_size]u8 {
    try validatePlayer(player);
    var out: [player_record_size]u8 = undefined;
    var p: usize = 0;
    put(u32, &out, &p, player_record_size);
    put(u16, &out, &p, 1);
    put(u64, &out, &p, player.id);
    for (player.feet) |v| put(u64, &out, &p, @bitCast(v));
    put(u32, &out, &p, @bitCast(player.yaw));
    put(u32, &out, &p, @bitCast(player.pitch));
    put(u16, &out, &p, 1);
    put(u32, &out, &p, 1);
    put(u8, &out, &p, player.inventory orelse 0);
    return out;
}
pub fn decodePlayer(bytes: []const u8) Error!Player {
    var r: Reader = .{ .bytes = bytes };
    if (try r.int(u32) != bytes.len) return error.InvalidFormat;
    if (try r.int(u16) != 1) return error.UnsupportedVersion;
    var out: Player = undefined;
    out.id = try r.int(u64);
    for (&out.feet) |*v| v.* = @bitCast(try r.int(u64));
    out.yaw = @bitCast(try r.int(u32));
    out.pitch = @bitCast(try r.int(u32));
    const inventory_schema = try r.int(u16);
    const inventory_length = try r.int(u32);
    out.inventory = switch (inventory_schema) {
        0 => if (inventory_length == 0) null else return error.InvalidFormat,
        1 => blk: {
            if (inventory_length != 1) return error.InvalidFormat;
            const material = try r.int(u8);
            break :blk if (material == 0) null else material;
        },
        else => return error.UnsupportedVersion,
    };
    try r.done();
    try validatePlayer(out);
    return out;
}
pub fn readPlayer(reader: *Reader) Error!Player {
    const start = reader.pos;
    const length = try reader.int(u32);
    if (length < 52 or length > player_record_size) return error.InvalidFormat;
    _ = try reader.take(length - 4);
    return decodePlayer(reader.bytes[start..reader.pos]);
}
pub fn validatePlayers(bytes: []const u8, count: u64) Error!void {
    if (count > bytes.len / 52) return error.InvalidFormat;
    var previous: ?u64 = null;
    var r: Reader = .{ .bytes = bytes };
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const player = try readPlayer(&r);
        if (previous) |id| {
            if (player.id <= id) return error.InvalidFormat;
        }
        previous = player.id;
    }
    try r.done();
}

pub const Descriptor = struct { dimensions: [3]u32, generator_id: u16, seed: u64, settings: []const u8 };
pub fn validateDescriptor(d: Descriptor) Error!void {
    var count: u64 = 1;
    for (d.dimensions) |dim| {
        if (dim < 2 or !std.math.isPowerOfTwo(dim) or dim > std.math.maxInt(u32) / 32) return error.InvalidDescriptor;
        count = try mul(count, dim);
    }
    if (count > 0x100000000) return error.InvalidDescriptor;
    switch (d.generator_id) {
        0 => if (d.seed != 0 or d.settings.len != 0) return error.InvalidDescriptor,
        1 => {
            if (d.settings.len != 39) return error.InvalidDescriptor;
            var r: Reader = .{ .bytes = d.settings };
            const scale: f64 = @bitCast(try r.int(u64));
            const octaves = try r.int(u8);
            const lacunarity: f64 = @bitCast(try r.int(u64));
            const persistence: f64 = @bitCast(try r.int(u64));
            const present = try r.int(u8);
            const base = try r.int(u32);
            const height: f64 = @bitCast(try r.int(u64));
            _ = try r.int(u8);
            if (!std.math.isFinite(scale) or scale <= 0 or octaves == 0 or !std.math.isFinite(lacunarity) or lacunarity <= 0 or !std.math.isFinite(persistence) or persistence < 0 or !std.math.isFinite(height) or height < 0 or present > 1 or (present == 0 and base != 0)) return error.InvalidDescriptor;
            var frequency = 1.0 / scale;
            var amplitude: f64 = 1;
            var total: f64 = 0;
            const width: f64 = @floatFromInt(@as(u64, d.dimensions[0]) * 32);
            const last_y: f64 = @floatFromInt(@as(u64, d.dimensions[1]) * 32 - 1);
            for (0..octaves) |i| {
                const period = @max(1.0, @round(width * frequency));
                if (!std.math.isFinite(frequency) or frequency <= 0 or !std.math.isFinite(period) or period >= 0x1p63 or (width - 1) * (period / width) >= 0x1p63 or !std.math.isFinite(last_y * frequency) or last_y * frequency >= 0x1p63 or !std.math.isFinite(amplitude)) return error.InvalidDescriptor;
                total += amplitude;
                if (!std.math.isFinite(total)) return error.InvalidDescriptor;
                if (i + 1 < octaves) {
                    frequency *= lacunarity;
                    amplitude *= persistence;
                }
            }
        },
        else => return error.InvalidDescriptor,
    }
}
pub fn encodeDescriptor(allocator: std.mem.Allocator, d: Descriptor) ![]u8 {
    try validateDescriptor(d);
    const out = try allocator.alloc(u8, 41 + d.settings.len);
    var p: usize = 0;
    put(u16, out, &p, 1);
    put(u16, out, &p, 1);
    put(u16, out, &p, 32);
    for (d.dimensions) |dim| put(u32, out, &p, dim);
    put(u8, out, &p, 1);
    put(u16, out, &p, d.generator_id);
    put(u32, out, &p, 1);
    put(u64, out, &p, d.seed);
    put(u32, out, &p, @intCast(d.settings.len));
    @memcpy(out[p..][0..d.settings.len], d.settings);
    p += d.settings.len;
    put(u32, out, &p, 60);
    return out;
}
pub fn decodeDescriptor(bytes: []const u8) Error!Descriptor {
    var r: Reader = .{ .bytes = bytes };
    if (try r.int(u16) != 1 or try r.int(u16) != 1 or try r.int(u16) != 32) return error.UnsupportedVersion;
    var d: Descriptor = undefined;
    for (&d.dimensions) |*dim| dim.* = try r.int(u32);
    if (try r.int(u8) != 1) return error.InvalidDescriptor;
    d.generator_id = try r.int(u16);
    if (try r.int(u32) != 1) return error.UnsupportedVersion;
    d.seed = try r.int(u64);
    const n = try r.int(u32);
    if (n > 39) return error.InvalidDescriptor;
    d.settings = try r.take(n);
    if (try r.int(u32) != 60) return error.InvalidDescriptor;
    try r.done();
    try validateDescriptor(d);
    return d;
}

pub const Formation = struct { high_endpoint: [3]u32, direction: u8, length: u32, section: u32 };
pub const CustomRoad = struct { formation: ?Formation = null };
pub const Timer = struct { cell: u16, kind: u8, deadline: u64 };
pub const MetadataView = struct { roads: []const CustomRoad = &.{}, construction: []const u16 = &.{}, timers: []const Timer = &.{} };
pub fn encodeMetadata(allocator: std.mem.Allocator, view: MetadataView) ![]u8 {
    if (view.roads.len > cell_count or view.construction.len > cell_count or view.timers.len > cell_count) return error.InvalidMetadata;
    var roads_len: usize = 0;
    for (view.roads) |road| {
        roads_len += if (road.formation != null) @as(usize, 23) else 2;
        if (road.formation) |f| {
            if (f.direction > 3 or f.length == 0 or f.section >= f.length) return error.InvalidMetadata;
        }
    }
    var seen = [_]bool{false} ** cell_count;
    for (view.construction) |cell| {
        if (cell >= cell_count or seen[cell]) return error.InvalidMetadata;
        seen[cell] = true;
    }
    @memset(&seen, false);
    for (view.timers) |timer| {
        if (timer.cell >= cell_count or seen[timer.cell] or timer.kind > 1) return error.InvalidMetadata;
        seen[timer.cell] = true;
    }
    const size = roads_len + view.construction.len * 2 + view.timers.len * 11 + @as(usize, if (roads_len > 0) 9 else 0) + @as(usize, if (view.construction.len > 0) 9 else 0) + @as(usize, if (view.timers.len > 0) 9 else 0);
    const out = try allocator.alloc(u8, size);
    var p: usize = 0;
    if (roads_len > 0) {
        sectionHeader(out, &p, 1, roads_len);
        for (view.roads) |road| {
            put(u8, out, &p, 0);
            put(u8, out, &p, @intFromBool(road.formation != null));
            if (road.formation) |f| {
                for (f.high_endpoint) |value| put(u32, out, &p, value);
                put(u8, out, &p, f.direction);
                put(u32, out, &p, f.length);
                put(u32, out, &p, f.section);
            }
        }
    }
    if (view.construction.len > 0) {
        sectionHeader(out, &p, 2, view.construction.len * 2);
        for (view.construction) |cell| put(u16, out, &p, cell);
    }
    if (view.timers.len > 0) {
        sectionHeader(out, &p, 3, view.timers.len * 11);
        for (view.timers) |timer| {
            put(u16, out, &p, timer.cell);
            put(u8, out, &p, timer.kind);
            put(u64, out, &p, timer.deadline);
        }
    }
    return out;
}
fn sectionHeader(out: []u8, p: *usize, kind: u16, size: usize) void {
    put(u16, out, p, kind);
    put(u16, out, p, 1);
    put(u8, out, p, 1);
    put(u32, out, p, @intCast(size));
}

test "chunk codecs roundtrip air, deferred trailing air, raw fallback and corruption" {
    const a = std.testing.allocator;
    const uuid = [_]u8{7} ** 16;
    var blocks = [_]u8{0} ** cell_count;
    const scenarios = [_]usize{ 0, 1, cell_count };
    for (scenarios) |n| {
        @memset(&blocks, 0);
        for (0..n) |i| blocks[i] = @intCast(i % 2 + 1);
        const bytes = try encodeChunk(a, uuid, .{ .id = 0xffffffff, .revision = 0xffffffffffffffff, .is_unreachable = true, .blocks = &blocks, .metadata = &.{} });
        defer a.free(bytes);
        try std.testing.expectEqual(@as(u8, if (n == cell_count) 0 else 1), bytes[17]);
        var decoded = try decodeChunk(a, uuid, bytes, .{ 32768, 32768, 4 });
        defer decoded.deinit(a);
        try std.testing.expectEqualSlices(u8, &blocks, decoded.blocks);
        try validateChunkRecord(uuid, bytes, .{ 32768, 32768, 4 });
        bytes[8] ^= 1;
        try std.testing.expectError(error.ChecksumMismatch, validateChunkRecord(uuid, bytes, .{ 32768, 32768, 4 }));
        bytes[8] ^= 1;
        try std.testing.expectError(error.InvalidFormat, validateChunkRecord(uuid, bytes[0 .. bytes.len - 1], .{ 32768, 32768, 4 }));
    }
}
test "metadata validates custom correspondence and independent section identities" {
    const a = std.testing.allocator;
    var blocks = [_]u8{0} ** cell_count;
    blocks[9] = 255;
    const bytes = try encodeMetadata(a, .{ .roads = &.{.{}}, .construction = &.{9}, .timers = &.{.{ .cell = 9, .kind = 1, .deadline = 99 }} });
    defer a.free(bytes);
    try validateMetadata(&blocks, bytes, .{ 512, 256, 8 });
    blocks[9] = 0;
    try std.testing.expectError(error.InvalidFormat, validateMetadata(&blocks, bytes, .{ 512, 256, 8 }));
    try std.testing.expectError(error.InvalidMetadata, encodeMetadata(a, .{ .construction = &.{ 9, 9 } }));
    blocks[9] = 255;
    try std.testing.expectError(error.InvalidMetadata, validateMetadata(&blocks, &.{}, .{ 512, 256, 8 }));
}
test "descriptor global and player strict wire roundtrips" {
    const a = std.testing.allocator;
    const d: Descriptor = .{ .dimensions = .{ 512, 256, 8 }, .generator_id = 0, .seed = 0, .settings = &.{} };
    const bytes = try encodeDescriptor(a, d);
    defer a.free(bytes);
    const decoded = try decodeDescriptor(bytes);
    try std.testing.expectEqual(d.dimensions, decoded.dimensions);
    const global = encodeGlobal(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), try decodeGlobal(&global));
    const player: Player = .{ .id = 8, .feet = .{ -1, 2, 3 }, .yaw = 1, .pitch = 2 };
    const p = try encodePlayer(player);
    const actual = try decodePlayer(&p);
    try std.testing.expectEqual(player, actual);
    try validatePlayers(&p, 1);
    try std.testing.expectError(error.InvalidFormat, validatePlayers(&p, 2));
    try std.testing.expectError(error.InvalidFormat, encodePlayer(.{ .id = 1, .feet = .{ std.math.nan(f64), 0, 0 }, .yaw = 0, .pitch = 0 }));
    try std.testing.expectError(error.Overflow, add(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.Overflow, mul(std.math.maxInt(u64), 12));
    try std.testing.expectError(error.InvalidFormat, range(9, 2, 10));
}
fn allocationScenario(a: std.mem.Allocator) !void {
    var blocks = [_]u8{0} ** cell_count;
    blocks[0] = 255;
    const metadata = try encodeMetadata(a, .{ .roads = &.{.{}} });
    defer a.free(metadata);
    const bytes = try encodeChunk(a, [_]u8{0} ** 16, .{ .id = 0, .revision = 1, .is_unreachable = false, .blocks = &blocks, .metadata = metadata });
    defer a.free(bytes);
    var decoded = try decodeChunk(a, [_]u8{0} ** 16, bytes, .{ 1, 1, 1 });
    defer decoded.deinit(a);
    var restored = try decodeMetadata(a, decoded.blocks, decoded.metadata, .{ 2, 2, 2 });
    defer restored.deinit(a);
    const descriptor = try encodeDescriptor(a, .{ .dimensions = .{ 2, 2, 2 }, .generator_id = 0, .seed = 0, .settings = &.{} });
    defer a.free(descriptor);
}
test "all codec allocation failures release owned buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

pub const TerrainSettings = struct { noise_scale: f64 = 192, octaves: u8 = 4, lacunarity: f64 = 2, persistence: f64 = 0.5, base_height: ?u32 = null, height_amplitude: f64 = 48, dirt_depth: u8 = 4 };
pub fn encodeTerrainSettings(settings: TerrainSettings) [39]u8 {
    var out: [39]u8 = undefined;
    var p: usize = 0;
    put(u64, &out, &p, @bitCast(settings.noise_scale));
    put(u8, &out, &p, settings.octaves);
    put(u64, &out, &p, @bitCast(settings.lacunarity));
    put(u64, &out, &p, @bitCast(settings.persistence));
    put(u8, &out, &p, @intFromBool(settings.base_height != null));
    put(u32, &out, &p, settings.base_height orelse 0);
    put(u64, &out, &p, @bitCast(settings.height_amplitude));
    put(u8, &out, &p, settings.dirt_depth);
    return out;
}
pub fn decodeTerrainSettings(bytes: []const u8) Error!TerrainSettings {
    if (bytes.len != 39) return error.InvalidDescriptor;
    var r: Reader = .{ .bytes = bytes };
    const scale: f64 = @bitCast(try r.int(u64));
    const octaves = try r.int(u8);
    const lacunarity: f64 = @bitCast(try r.int(u64));
    const persistence: f64 = @bitCast(try r.int(u64));
    const present = try r.int(u8);
    const base = try r.int(u32);
    if (present > 1 or (present == 0 and base != 0)) return error.InvalidDescriptor;
    const amplitude: f64 = @bitCast(try r.int(u64));
    const dirt = try r.int(u8);
    return .{ .noise_scale = scale, .octaves = octaves, .lacunarity = lacunarity, .persistence = persistence, .base_height = if (present == 1) base else null, .height_amplitude = amplitude, .dirt_depth = dirt };
}

pub const Metadata = struct {
    roads: []CustomRoad,
    construction: []u16,
    timers: []Timer,
    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.roads);
        allocator.free(self.construction);
        allocator.free(self.timers);
        self.* = undefined;
    }
};
pub fn decodeMetadata(allocator: std.mem.Allocator, blocks: []const u8, bytes: []const u8, dimensions: [3]u32) !Metadata {
    try validateMetadata(blocks, bytes, dimensions);
    var road_bytes: []const u8 = &.{};
    var construction_bytes: []const u8 = &.{};
    var timer_bytes: []const u8 = &.{};
    var r: Reader = .{ .bytes = bytes };
    while (r.pos < bytes.len) {
        const kind = try r.int(u16);
        _ = try r.take(3);
        const n = try r.int(u32);
        const payload = try r.take(n);
        switch (kind) {
            1 => road_bytes = payload,
            2 => construction_bytes = payload,
            3 => timer_bytes = payload,
            else => unreachable,
        }
    }
    var count: usize = 0;
    for (blocks) |b| {
        if (b == 255) count += 1;
    }
    const roads = try allocator.alloc(CustomRoad, count);
    errdefer allocator.free(roads);
    const construction = try allocator.alloc(u16, construction_bytes.len / 2);
    errdefer allocator.free(construction);
    const timers = try allocator.alloc(Timer, timer_bytes.len / 11);
    errdefer allocator.free(timers);
    r = .{ .bytes = road_bytes };
    for (roads) |*road| {
        _ = try r.int(u8);
        const formed = try r.int(u8);
        road.* = .{};
        if (formed == 1) {
            var f: Formation = undefined;
            for (&f.high_endpoint) |*value| value.* = try r.int(u32);
            f.direction = try r.int(u8);
            f.length = try r.int(u32);
            f.section = try r.int(u32);
            road.formation = f;
        }
    }
    r = .{ .bytes = construction_bytes };
    for (construction) |*cell| cell.* = try r.int(u16);
    r = .{ .bytes = timer_bytes };
    for (timers) |*timer| timer.* = .{ .cell = try r.int(u16), .kind = try r.int(u8), .deadline = try r.int(u64) };
    return .{ .roads = roads, .construction = construction, .timers = timers };
}

test "terrain settings retain automatic height and reject invalid layout parameters" {
    const settings = encodeTerrainSettings(.{});
    const decoded = try decodeTerrainSettings(&settings);
    try std.testing.expectEqual(@as(?u32, null), decoded.base_height);
    try validateDescriptor(.{ .dimensions = .{ 512, 256, 8 }, .generator_id = 1, .seed = 1, .settings = &settings });
    for ([_][3]u32{ .{ 1, 2, 2 }, .{ 3, 2, 2 }, .{ 134217728, 2, 2 }, .{ 65536, 65536, 2 } }) |dims| try std.testing.expectError(error.InvalidDescriptor, validateDescriptor(.{ .dimensions = dims, .generator_id = 0, .seed = 0, .settings = &.{} }));
    const bad = encodeTerrainSettings(.{ .noise_scale = std.math.nan(f64) });
    try std.testing.expectError(error.InvalidDescriptor, validateDescriptor(.{ .dimensions = .{ 2, 2, 2 }, .generator_id = 1, .seed = 1, .settings = &bad }));
    const d = try std.testing.allocator.dupe(u8, &settings);
    defer std.testing.allocator.free(d);
    d[25] = 2;
    try std.testing.expectError(error.InvalidDescriptor, decodeTerrainSettings(d));
}
test "exact air record framing and hash domain binds world identity" {
    const a = std.testing.allocator;
    const uuid = [_]u8{0} ** 16;
    const blocks = [_]u8{0} ** cell_count;
    const record = try encodeChunk(a, uuid, .{ .id = 0x78563412, .revision = 0x0807060504030201, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
    defer a.free(record);
    try std.testing.expectEqual(@as(usize, 58), record.len);
    try std.testing.expectEqualSlices(u8, &.{ 58, 0, 0, 0, 0x12, 0x34, 0x56, 0x78, 1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, record[0..26]);
    try std.testing.expectError(error.ChecksumMismatch, validateChunkRecord([_]u8{1} ** 16, record, .{ 512, 256, 8 }));
    const wrong = hash("ZGW-CHUNK-1", &.{ &uuid, record[0..26] });
    try std.testing.expect(!std.mem.eql(u8, &wrong, record[26..]));
}
test "metadata sections reject unknown flags schemas duplicates and truncation" {
    var blocks = [_]u8{0} ** cell_count;
    for ([_]u16{ 0, 4, 65535 }) |kind| {
        var bytes: [11]u8 = undefined;
        var p: usize = 0;
        sectionHeader(&bytes, &p, kind, 2);
        put(u16, &bytes, &p, 0);
        try std.testing.expectError(error.InvalidMetadata, validateMetadata(&blocks, &bytes, .{ 2, 2, 2 }));
    }
    const a = std.testing.allocator;
    const bytes = try encodeMetadata(a, .{ .construction = &.{ 0, 32767 } });
    defer a.free(bytes);
    for ([_]usize{ 2, 4 }) |index| {
        bytes[index] = 0;
        try std.testing.expectError(error.InvalidMetadata, validateMetadata(&blocks, bytes, .{ 2, 2, 2 }));
        bytes[index] = 1;
    }
    try std.testing.expectError(error.InvalidFormat, validateMetadata(&blocks, bytes[0 .. bytes.len - 1], .{ 2, 2, 2 }));
    bytes[9] = 0xff;
    bytes[10] = 0xff;
    try std.testing.expectError(error.InvalidMetadata, validateMetadata(&blocks, bytes, .{ 2, 2, 2 }));
}

fn resealChunk(uuid: Uuid, bytes: []u8) void {
    const digest = hash("ZGW-CHUNK-1\x00", &.{ &uuid, bytes[0 .. bytes.len - 32] });
    @memcpy(bytes[bytes.len - 32 ..], &digest);
}
test "structurally invalid RLE is rejected even with matching checksum" {
    const a = std.testing.allocator;
    const uuid = [_]u8{0} ** 16;
    var blocks = [_]u8{0} ** cell_count;
    blocks[0] = 1;
    const bytes = try encodeChunk(a, uuid, .{ .id = 0, .revision = 0, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
    defer a.free(bytes);
    bytes[23] = 0;
    resealChunk(uuid, bytes);
    try std.testing.expectError(error.InvalidFormat, validateChunkRecord(uuid, bytes, .{ 2, 2, 2 }));
    bytes[23] = 1;
    bytes[17] = 2;
    resealChunk(uuid, bytes);
    try std.testing.expectError(error.UnsupportedCodec, validateChunkRecord(uuid, bytes, .{ 2, 2, 2 }));
    bytes[17] = 1;
    bytes[16] = 2;
    resealChunk(uuid, bytes);
    try std.testing.expectError(error.InvalidFormat, validateChunkRecord(uuid, bytes, .{ 2, 2, 2 }));
    bytes[16] = 0;
    bytes[18] = 1;
    resealChunk(uuid, bytes);
    try std.testing.expectError(error.InvalidFormat, validateChunkRecord(uuid, bytes, .{ 2, 2, 2 }));
}
test "all metadata sections may reach independent bounds and full wire record cap" {
    const a = std.testing.allocator;
    const roads = try a.alloc(CustomRoad, cell_count);
    defer a.free(roads);
    const construction = try a.alloc(u16, cell_count);
    defer a.free(construction);
    const timers = try a.alloc(Timer, cell_count);
    defer a.free(timers);
    for (0..cell_count) |i| {
        roads[i] = .{ .formation = .{ .high_endpoint = .{ 63, 63, 63 }, .direction = 3, .length = 32768, .section = @intCast(i) } };
        construction[i] = @intCast(i);
        timers[i] = .{ .cell = @intCast(i), .kind = 1, .deadline = std.math.maxInt(u64) };
    }
    const metadata = try encodeMetadata(a, .{ .roads = roads, .construction = construction, .timers = timers });
    defer a.free(metadata);
    try std.testing.expectEqual(@as(usize, maximum_metadata_size), metadata.len);
    const blocks = [_]u8{255} ** cell_count;
    try validateMetadata(&blocks, metadata, .{ 2, 2, 2 });
    var decoded = try decodeMetadata(a, &blocks, metadata, .{ 2, 2, 2 });
    defer decoded.deinit(a);
    try std.testing.expectEqual(@as(usize, cell_count), decoded.roads.len);
    try std.testing.expectEqualDeep(roads[32767], decoded.roads[32767]);
    // Raw repeated custom bytes are legal input even though our encoder would use RLE.
    const bytes = try a.alloc(u8, maximum_chunk_size);
    defer a.free(bytes);
    var p: usize = 0;
    put(u32, bytes, &p, maximum_chunk_size);
    put(u32, bytes, &p, 0);
    put(u64, bytes, &p, 1);
    put(u8, bytes, &p, 0);
    put(u8, bytes, &p, 0);
    put(u32, bytes, &p, cell_count);
    @memcpy(bytes[p..][0..cell_count], &blocks);
    p += cell_count;
    put(u32, bytes, &p, maximum_metadata_size);
    @memcpy(bytes[p..][0..metadata.len], metadata);
    resealChunk([_]u8{0} ** 16, bytes);
    try validateChunkRecord([_]u8{0} ** 16, bytes, .{ 2, 2, 2 });
    metadata[11] = 64;
    try std.testing.expectError(error.InvalidMetadata, validateMetadata(&blocks, metadata, .{ 2, 2, 2 }));
}

pub const max_chunk_record_bytes = maximum_chunk_size;

test "inventory schema roundtrips all carried materials and migrates legacy empty players" {
    for ([_]?u8{ null, 2, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14 }) |material| {
        const player: Player = .{ .id = 4, .feet = .{ 1, 2, 3 }, .yaw = 0.5, .pitch = 0.25, .inventory = material };
        const encoded = try encodePlayer(player);
        try std.testing.expectEqualDeep(player, try decodePlayer(&encoded));
        try validatePlayers(&encoded, 1);
    }
    const encoded = try encodePlayer(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    var legacy = encoded[0..52].*;
    var offset: usize = 0;
    put(u32, &legacy, &offset, 52);
    offset = 46;
    put(u16, &legacy, &offset, 0);
    put(u32, &legacy, &offset, 0);
    try std.testing.expectEqual(null, (try decodePlayer(&legacy)).inventory);
    try validatePlayers(&legacy, 1);
    var invalid = encoded;
    invalid[46] = 2;
    try std.testing.expectError(error.UnsupportedVersion, decodePlayer(&invalid));
    for ([_]u8{ 1, 3, 7, 15, 255 }) |material| {
        invalid = encoded;
        invalid[52] = material;
        try std.testing.expectError(error.InvalidFormat, decodePlayer(&invalid));
    }
    invalid = encoded;
    invalid[48] = 2;
    try std.testing.expectError(error.InvalidFormat, decodePlayer(&invalid));
    try std.testing.expectError(error.InvalidFormat, decodePlayer(encoded[0..52]));
    try std.testing.expectError(error.InvalidFormat, validatePlayers(&encoded, std.math.maxInt(u64)));
}
