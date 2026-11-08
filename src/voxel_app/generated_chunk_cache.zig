//! Worker-owned, bounded storage for immutable generated chunks. Payloads and
//! index storage use one stable backing allocator, independently of live state.
const std = @import("std");
const ChunkId = @import("consts.zig").ChunkId;
const WorldChunk = @import("world.zig").WorldChunk;
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;

pub const Cache = struct {
    /// At most 4 MiB of raw block arrays at the default, plus bounded headers/indexes.
    max_entries: usize = 128,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    entries: std.AutoArrayHashMapUnmanaged(ChunkId, WorldChunk) = .empty,
    eviction_cursor: usize = 0,

    /// Borrowed pointers remain valid only until the next cache mutation.
    pub fn get(self: *Cache, id: ChunkId) ?*const WorldChunk {
        if (self.peek(id)) |chunk| {
            self.hits +%= 1;
            return chunk;
        }
        self.misses +%= 1;
        return null;
    }

    pub fn peek(self: *const Cache, id: ChunkId) ?*const WorldChunk {
        return self.entries.getPtr(id);
    }

    /// Takes ownership only on true. A disabled cache returns false. On error,
    /// the input and every existing entry retain their original ownership.
    /// Inputs must be generated values without allocated mutation metadata.
    pub fn insert(self: *Cache, allocator: std.mem.Allocator, id: ChunkId, chunk: WorldChunk) !bool {
        std.debug.assert(chunk.chunk_revision == 0);
        std.debug.assert(chunk.metadata.roads.capacity == 0);
        std.debug.assert(chunk.metadata.constructed.capacity == 0);
        std.debug.assert(chunk.metadata.timed.events.capacity == 0);
        if (self.max_entries == 0) {
            while (self.count() != 0) self.evictOne(allocator);
            return false;
        }

        // Reserve before releasing anything. A full cache reuses the victim's
        // slot, so replacement does not require capacity beyond the entry cap.
        const required = if (self.entries.contains(id))
            @min(self.count(), self.max_entries)
        else if (self.count() >= self.max_entries)
            self.max_entries
        else
            self.count() + 1;
        try self.entries.ensureTotalCapacity(allocator, required);
        if (self.take(id)) |previous| previous.deinit(allocator);
        while (self.count() >= self.max_entries) self.evictOne(allocator);
        self.entries.putAssumeCapacityNoClobber(id, chunk);
        return true;
    }

    /// Transfers the value to the caller, who must release it through the same
    /// backing allocator or clone it into a different allocation domain.
    pub fn take(self: *Cache, id: ChunkId) ?WorldChunk {
        const removed = self.entries.fetchSwapRemove(id) orelse return null;
        self.normalizeCursor();
        return removed.value;
    }

    pub fn remove(self: *Cache, allocator: std.mem.Allocator, id: ChunkId) void {
        if (self.take(id)) |chunk| chunk.deinit(allocator);
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.values()) |chunk| chunk.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Cache) usize {
        return self.entries.count();
    }

    /// Raw block allocations only; headers and hash-index spare capacity are separate.
    pub fn blockBytes(self: *const Cache) usize {
        var bytes: usize = 0;
        for (self.entries.values()) |chunk| {
            if (chunk.content == .blocks) bytes += @sizeOf(WorldChunkData);
        }
        return bytes;
    }

    fn normalizeCursor(self: *Cache) void {
        self.eviction_cursor = if (self.count() == 0) 0 else self.eviction_cursor % self.count();
    }

    fn evictOne(self: *Cache, allocator: std.mem.Allocator) void {
        std.debug.assert(self.count() != 0);
        self.normalizeCursor();
        const chunk = self.entries.values()[self.eviction_cursor];
        self.entries.swapRemoveAt(self.eviction_cursor);
        chunk.deinit(allocator);
        self.evictions +%= 1;
        self.eviction_cursor += 1;
        self.normalizeCursor();
    }
};

fn testChunk(allocator: std.mem.Allocator, material: @import("engine").voxel_chunk.BlockType) !WorldChunk {
    const data = try allocator.create(WorldChunkData);
    data.* = WorldChunkData.initFilled(material);
    return WorldChunk.initBlocks(data);
}

fn insertTestChunk(cache: *Cache, allocator: std.mem.Allocator, id: ChunkId, material: @import("engine").voxel_chunk.BlockType) !void {
    const chunk = try testChunk(allocator, material);
    errdefer chunk.deinit(allocator);
    try std.testing.expect(try cache.insert(allocator, id, chunk));
}

test "generated cache preserves data and counts only get lookups" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    try std.testing.expect(cache.get(9) == null);
    try insertTestChunk(&cache, allocator, 9, .stone);
    const stored = cache.get(9).?;
    try std.testing.expectEqual(.stone, stored.content.getBlock(.{ 31, 17, 0 }));
    try std.testing.expectEqual(@as(u16, 32768), stored.solid_block_count);
    try std.testing.expectEqual(@as(u64, 0), stored.chunk_revision);
    try std.testing.expect(stored.flags.solid_left and stored.flags.solid_top);
    try std.testing.expect(cache.peek(9) != null);
    try std.testing.expect(cache.peek(10) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    try std.testing.expectEqual(@sizeOf(WorldChunkData), cache.blockBytes());

    try std.testing.expect(try cache.insert(allocator, 10, WorldChunk.initEmpty()));
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@sizeOf(WorldChunkData), cache.blockBytes());
}

test "replacement take remove and deinit release each owned allocation once" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    {
        var cache: Cache = .{ .max_entries = 2 };
        defer cache.deinit(allocator);
        try insertTestChunk(&cache, allocator, 1, .stone);
        try insertTestChunk(&cache, allocator, 1, .snow);
        try std.testing.expectEqual(@as(usize, 1), cache.count());
        try std.testing.expectEqual(@as(u64, 0), cache.evictions);
        const taken = cache.take(1).?;
        defer taken.deinit(allocator);
        try std.testing.expectEqual(.snow, taken.content.getBlock(.{ 0, 0, 0 }));
        try std.testing.expectEqual(@as(usize, 0), cache.blockBytes());
        try std.testing.expect(cache.take(1) == null);
        try insertTestChunk(&cache, allocator, 2, .stone);
        cache.remove(allocator, 2);
        cache.remove(allocator, 2);
        try insertTestChunk(&cache, allocator, 3, .sand);
    }
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "round robin eviction bounds entries and reuses reserved index storage" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    var cache: Cache = .{ .max_entries = 3 };
    defer cache.deinit(allocator);
    for (0..3) |id| try std.testing.expect(try cache.insert(allocator, @intCast(id), WorldChunk.initEmpty()));
    const allocations = counted.allocations;
    for (3..100) |id| {
        try std.testing.expect(try cache.insert(allocator, @intCast(id), WorldChunk.initEmpty()));
        try std.testing.expectEqual(@as(usize, 3), cache.count());
        try std.testing.expect(cache.peek(@intCast(id)) != null);
    }
    try std.testing.expectEqual(allocations, counted.allocations);
    try std.testing.expectEqual(@as(u64, 97), cache.evictions);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
}

test "reduced and disabled cache limits release retained entries and preserve caller ownership" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{ .max_entries = 3 };
    defer cache.deinit(allocator);
    for (0..3) |id| try insertTestChunk(&cache, allocator, @intCast(id), .stone);
    cache.max_entries = 1;
    try insertTestChunk(&cache, allocator, 0, .snow);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(.snow, cache.peek(0).?.content.getBlock(.{ 8, 8, 8 }));
    try std.testing.expectEqual(@as(u64, 2), cache.evictions);
    cache.max_entries = 0;
    const input = try testChunk(allocator, .sand);
    defer input.deinit(allocator);
    try std.testing.expect(!try cache.insert(allocator, 4, input));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), cache.blockBytes());
    try std.testing.expectEqual(@as(u64, 3), cache.evictions);
    try std.testing.expectEqual(.sand, input.content.getBlock(.{ 1, 1, 1 }));
}

test "index allocation failure retains existing chunks and caller ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    try insertTestChunk(&cache, allocator, 1, .stone);
    // Fill existing metadata capacity without allocating block arrays.
    const capacity = cache.entries.capacity();
    for (2..capacity + 1) |id| try std.testing.expect(try cache.insert(allocator, @intCast(id), WorldChunk.initEmpty()));
    const input = try testChunk(allocator, .snow);
    defer input.deinit(allocator);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, cache.insert(allocator, @intCast(capacity + 1), input));
    try std.testing.expectEqual(capacity, cache.count());
    try std.testing.expectEqual(@as(u64, 0), cache.evictions);
    try std.testing.expectEqual(.stone, cache.peek(1).?.content.getBlock(.{ 2, 2, 2 }));
    try std.testing.expectEqual(.snow, input.content.getBlock(.{ 2, 2, 2 }));
    try std.testing.expectEqual(@sizeOf(WorldChunkData), cache.blockBytes());
}
