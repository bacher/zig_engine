//! Durable obligations, independent of runtime scheduling and loaded chunks.
//! A snapshot replaces the complete pending set. Records are canonical by kind
//! then chunk ID, so duplicates, unknown work, and malformed bounds fail closed.
const std = @import("std");

pub const Kind = enum(u8) { road_shape = 1 };
pub const Key = struct { kind: Kind, chunk_id: u32 };
pub const record_size: usize = 5;

pub fn lessThan(_: void, a: Key, b: Key) bool {
    return @intFromEnum(a.kind) < @intFromEnum(b.kind) or
        (a.kind == b.kind and a.chunk_id < b.chunk_id);
}

pub fn encodedSize(count: usize) !usize {
    return std.math.mul(usize, count, record_size);
}

fn chunkCount(dimensions: [3]u32) !u64 {
    var count: u64 = 1;
    for (dimensions) |dimension| {
        if (dimension == 0) return error.InvalidDeferredWork;
        count = try std.math.mul(u64, count, dimension);
    }
    return count;
}

fn read(bytes: *const [record_size]u8) !Key {
    return .{
        .kind = std.enums.fromInt(Kind, bytes[0]) orelse return error.InvalidDeferredWork,
        .chunk_id = std.mem.readInt(u32, bytes[1..5], .little),
    };
}

pub fn validate(bytes: []const u8, dimensions: [3]u32, max_entries: usize) !void {
    if (bytes.len % record_size != 0) return error.InvalidDeferredWork;
    if (bytes.len / record_size > max_entries) return error.Capacity;
    const chunks = try chunkCount(dimensions);
    var previous: ?Key = null;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += record_size) {
        const key = try read(bytes[offset..][0..record_size]);
        if (key.chunk_id >= chunks) return error.InvalidDeferredWork;
        if (previous) |last| if (!lessThan({}, last, key)) return error.InvalidDeferredWork;
        previous = key;
    }
}

/// Validate the complete set before allocating or returning any work.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, dimensions: [3]u32, max_entries: usize) ![]Key {
    try validate(bytes, dimensions, max_entries);
    const keys = try allocator.alloc(Key, bytes.len / record_size);
    for (keys, 0..) |*key, index| key.* = try read(bytes[index * record_size ..][0..record_size]);
    return keys;
}

/// Callers supply sorted unique keys; queue snapshots provide this ordering.
pub fn encode(allocator: std.mem.Allocator, keys: []const Key, dimensions: [3]u32, max_entries: usize) ![]u8 {
    if (keys.len > max_entries) return error.Capacity;
    const chunks = try chunkCount(dimensions);
    for (keys, 0..) |key, index| {
        if (key.chunk_id >= chunks) return error.InvalidDeferredWork;
        if (index != 0 and !lessThan({}, keys[index - 1], key)) return error.InvalidDeferredWork;
    }
    const bytes = try allocator.alloc(u8, try encodedSize(keys.len));
    for (keys, 0..) |key, index| {
        bytes[index * record_size] = @intFromEnum(key.kind);
        std.mem.writeInt(u32, bytes[index * record_size + 1 ..][0..4], key.chunk_id, .little);
    }
    return bytes;
}

test "pending work has canonical typed bounded round trips including empty state" {
    const a = std.testing.allocator;
    const dimensions = [3]u32{ 4, 4, 4 };
    const keys = [_]Key{ .{ .kind = .road_shape, .chunk_id = 3 }, .{ .kind = .road_shape, .chunk_id = 63 } };
    const bytes = try encode(a, &keys, dimensions, keys.len);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 10), bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 0, 0, 0, 1, 63, 0, 0, 0 }, bytes);
    const decoded = try decode(a, bytes, dimensions, keys.len);
    defer a.free(decoded);
    try std.testing.expectEqualSlices(Key, &keys, decoded);
    const empty = try encode(a, &.{}, dimensions, 0);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const empty_keys = try decode(a, empty, dimensions, 0);
    defer a.free(empty_keys);
    try std.testing.expectEqual(@as(usize, 0), empty_keys.len);
}

test "pending work rejects unknown duplicate unsorted truncated and out of world keys before allocation" {
    const dimensions = [3]u32{ 2, 2, 2 };
    const invalid = [_][]const u8{
        &.{ 2, 0, 0, 0, 0 },
        &.{ 1, 1, 0, 0, 0, 1, 1, 0, 0, 0 },
        &.{ 1, 2, 0, 0, 0, 1, 1, 0, 0, 0 },
        &.{ 1, 0, 0, 0 },
        &.{ 1, 8, 0, 0, 0 },
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (invalid) |bytes| try std.testing.expectError(error.InvalidDeferredWork, decode(failing.allocator(), bytes, dimensions, 2));
    try std.testing.expectError(error.Capacity, decode(failing.allocator(), &.{ 1, 0, 0, 0, 0 }, dimensions, 0));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "pending work encode checks complete input before allocation" {
    const dimensions = [3]u32{ 2, 2, 2 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const invalid = [_]Key{ .{ .kind = .road_shape, .chunk_id = 1 }, .{ .kind = .road_shape, .chunk_id = 1 } };
    try std.testing.expectError(error.InvalidDeferredWork, encode(failing.allocator(), &invalid, dimensions, 2));
    try std.testing.expectError(error.Capacity, encode(failing.allocator(), &invalid, dimensions, 1));
    try std.testing.expectError(error.Overflow, encodedSize(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}
