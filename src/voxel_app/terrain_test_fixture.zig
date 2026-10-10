//! Shared terrain setup for player movement and climb regressions.
const std = @import("std");
const engine = @import("engine");
const World = @import("world.zig").World;
const Cell = @import("terrain_collision.zig").Cell;

pub const Fixture = struct {
    world: World,

    pub fn init() !Fixture {
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
        var world = try World.init(std.testing.allocator, &layout);
        errdefer world.deinit();
        for (0..4) |z| for (0..4) |y| for (0..4) |x| {
            try world.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, @import("world.zig").WorldChunk.initEmpty());
        };
        return .{ .world = world };
    }

    pub fn deinit(self: *Fixture) void {
        self.world.deinit();
    }

    pub fn set(self: *Fixture, cell: Cell, block: engine.voxel_chunk.BlockType) void {
        const origin: Cell = @as(Cell, self.world.layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
        var stored = cell + origin;
        stored[0] = @mod(stored[0], self.world.layout.size_in_blocks[0]);
        self.world.setBlock(@as(@Vector(3, u32), @intCast(stored)), block);
    }

    pub fn fill(self: *Fixture, first: Cell, last: Cell, block: engine.voxel_chunk.BlockType) void {
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) self.set(.{ x, y, z }, block);
            }
        }
    }

    pub fn floor(self: *Fixture) void {
        self.fill(.{ -16, -16, -1 }, .{ 16, 16, -1 }, .stone);
    }

    pub fn hole(self: *Fixture, depth: i64) void {
        self.fill(.{ -4, -2, -depth - 1 }, .{ 4, 2, -1 }, .stone);
        self.fill(.{ 1, 0, -depth }, .{ 1, 0, -1 }, .none);
    }
};
