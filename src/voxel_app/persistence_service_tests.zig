//! Bounded seeded software-restart integration evidence through public service APIs.
//! This combines acknowledged edits, WAL/base saves, discard of unsaved suffixes,
//! recovery and continued editing. Power-cut behavior is covered by storage models.
const std = @import("std");
const engine = @import("engine");
const service_api = @import("world_data_service.zig");
const format = @import("persistence/format.zig");
const storage = @import("persistence/storage.zig");
const persistence = @import("persistence/coordinator.zig");
const world = @import("world.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const positions = [_]engine.ChunkCoords{ .{ 1, 1, 1 }, .{ 2, 1, 1 }, .{ 1, 2, 1 }, .{ 2, 2, 1 } };

const Model = struct {
    blocks: [4][32768]u8,
    revisions: [4]u64 = @splat(0),
    tick: u64 = 0,
    player: ?format.Player = null,
    fn init(self: *Model) void {
        self.revisions = @splat(0);
        self.tick = 0;
        self.player = null;
        // Independent flat-world oracle: lower half of z-chunk1 is rock.
        for (&self.blocks) |*blocks| {
            @memset(blocks[0..16384], @intFromEnum(engine.voxel_chunk.BlockType.stone));
            @memset(blocks[16384..], 0);
            // Flat generator's three fixed snow markers on the rock surface.
            blocks[15 * 1024] = @intFromEnum(engine.voxel_chunk.BlockType.snow);
            blocks[15 * 1024 + 1] = @intFromEnum(engine.voxel_chunk.BlockType.snow);
            blocks[15 * 1024 + 32] = @intFromEnum(engine.voxel_chunk.BlockType.snow);
        }
    }
    fn expectChunk(self: *const Model, index: usize, chunk: world.WorldChunk) !void {
        try std.testing.expectEqual(self.revisions[index], chunk.chunk_revision);
        const data = chunk.content.toData();
        try std.testing.expectEqualSlices(u8, &self.blocks[index], std.mem.asBytes(&data.blocks));
        try std.testing.expectEqual(@as(usize, 0), chunk.metadata.timed.events.items.len);
        try std.testing.expectEqual(@as(usize, 0), chunk.metadata.roads.items.len);
    }
};

const Harness = struct {
    const Trace = struct { chunk: usize, cell: usize, material: u8 };
    path: [:0]u8,
    layout: engine.WorldLayout,
    store: storage.Store,
    service: ?*service_api.WorldDataService = null,
    client: ?*service_api.Client = null,
    store_open: bool = false,
    seed: u64,
    action: usize = 0,
    trace: [44]Trace = undefined,
    fn printTrace(self: *const Harness) void {
        std.debug.print("public persistence software restart seed={d}, completed actions={d}\n", .{ self.seed, self.action });
        for (self.trace[0..self.action], 0..) |entry, index|
            std.debug.print("  action={d} chunk={d} cell={d} material={d}\n", .{ index, entry.chunk, entry.cell, entry.material });
    }
    fn init(self: *Harness, seed: u64) !void {
        self.seed = seed;
        self.action = 0;
        self.service = null;
        self.client = null;
        self.store_open = false;
        var uuid: [16]u8 = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        self.path = try std.fmt.allocPrintSentinel(a, "/private/tmp/persistence-seeded-service-{x}", .{uuid}, 0);
        errdefer a.free(self.path);
        self.layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
        const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
        defer a.free(descriptor);
        const global = format.encodeGlobal(0);
        self.store = try storage.Store.create(a, self.path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
        self.store_open = true;
        errdefer self.store.deinit();
        try self.start();
    }
    fn start(self: *Harness) !void {
        self.service = try service_api.WorldDataService.createPersistent(io, a, &self.layout, .flat, &self.store, .{});
        self.client = try self.service.?.createClient();
    }
    fn deinit(self: *Harness) void {
        if (self.service) |service| service.destroy();
        if (self.store_open) self.store.deinit();
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        a.free(self.path);
    }
    fn edit(self: *Harness, model: *Model, random: std.Random) !void {
        const index = random.uintLessThan(usize, positions.len);
        const site = random.uintLessThan(usize, 16);
        const x: u5 = @intCast(8 + 2 * (site % 4));
        const y: u5 = @intCast(8 + 2 * (site / 4));
        const cell = @as(usize, 16) * 1024 + @as(usize, y) * 32 + x;
        const material: engine.voxel_chunk.BlockType = if (random.boolean()) .snow else .sand;
        const remove = model.blocks[index][cell] != 0;
        const operation: world.BlockOperation = .{
            .block = .{ @as(u32, @intCast(positions[index][0])) * 32 + x, @as(u32, @intCast(positions[index][1])) * 32 + y, 48 },
            .action = if (remove) .remove else .{ .put = material },
        };
        errdefer std.debug.print("seeded service seed={d}, action={d}, chunk={d}, cell={d}, remove={}\n", .{ self.seed, self.action, index, cell, remove });
        const request = try self.client.?.trySubmitOperation(operation);
        self.trace[self.action] = .{ .chunk = index, .cell = cell, .material = if (remove) 0 else @intFromEnum(material) };
        self.action += 1;
        model.blocks[index][cell] = if (remove) 0 else @intFromEnum(material);
        model.revisions[index] += 1;
        var replies: std.ArrayList(service_api.ChunkResponse) = .empty;
        defer {
            for (replies.items) |reply| reply.deinit(a);
            replies.deinit(a);
        }
        // No subscriptions are needed for edits; each terminal reply owns its snapshot.
        const deadline = persistence.now(io) + 10 * std.time.ns_per_s;
        while (persistence.now(io) < deadline) {
            self.client.?.takeResponses(&replies);
            for (replies.items) |reply| if (reply.operation) |result| {
                if (result.request_id != request) continue;
                try std.testing.expectEqual(world.OperationStatus.success, result.status);
                try std.testing.expect(reply.data == .blocks);
                try model.expectChunk(index, reply.data.blocks.chunk);
                return;
            };
            for (replies.items) |reply| reply.deinit(a);
            replies.clearRetainingCapacity();
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.TestOperationTimeout;
    }
    fn save(self: *Harness, model: *Model, final: bool) !void {
        self.service.?.advanceTo(model.tick);
        if (model.player) |player| self.client.?.publishCheckpoint(player);
        const intent = self.service.?.requestSave(final);
        const deadline = persistence.now(io) + 10 * std.time.ns_per_s;
        while (persistence.now(io) < deadline) {
            const status = self.service.?.persistenceStatus();
            if (status.intent_id == intent and !status.active and (status.phase == .complete or status.phase == .failed)) {
                try std.testing.expectEqual(persistence.Phase.complete, status.phase);
                try std.testing.expectEqual(status.target_sequence, status.durable_sequence);
                return;
            }
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.TestSaveTimeout;
    }
    fn restart(self: *Harness, expected: *const Model) !void {
        // destroy cancels work but never saves the acknowledged unsaved suffix.
        self.service.?.destroy();
        self.service = null;
        self.client = null;
        self.store.deinit();
        self.store_open = false;
        self.store = try storage.Store.open(a, self.path, .{});
        self.store_open = true;
        try std.testing.expectEqual(expected.tick, try format.decodeGlobal(self.store.global));
        for (positions, 0..) |coords, index| {
            const encoded = try self.store.readChunk(a, self.layout.encodeChunkCoords(coords));
            if (encoded) |bytes| {
                defer a.free(bytes);
                var decoded = try format.decodeChunk(a, self.store.world_uuid, bytes, self.store.dimensions);
                defer decoded.deinit(a);
                try std.testing.expectEqual(expected.revisions[index], decoded.revision);
                try std.testing.expectEqualSlices(u8, &expected.blocks[index], decoded.blocks);
            } else try std.testing.expectEqual(@as(u64, 0), expected.revisions[index]);
        }
        try self.start();
        try std.testing.expectEqual(expected.tick, self.service.?.restoredTick());
        if (expected.player) |player| try std.testing.expectEqualDeep(player, self.service.?.restoredPlayer(player.id).?);
        // Exercise asynchronous persisted reload through public chunk subscriptions.
        for (positions, 0..) |coords, index| {
            const token = try self.client.?.tryRequestChunksInMode(.{ coords[0], coords[1] }, 1, 2, .blocks);
            var replies: std.ArrayList(service_api.ChunkResponse) = .empty;
            defer {
                for (replies.items) |reply| reply.deinit(a);
                replies.deinit(a);
            }
            var found = false;
            const deadline = persistence.now(io) + 10 * std.time.ns_per_s;
            while (!found and persistence.now(io) < deadline) {
                self.client.?.takeResponses(&replies);
                for (replies.items) |reply| if (reply.subscription_id == token and reply.data == .blocks) {
                    try expected.expectChunk(index, reply.data.blocks.chunk);
                    found = true;
                };
                if (!found) {
                    for (replies.items) |reply| reply.deinit(a);
                    replies.clearRetainingCapacity();
                    try std.Io.sleep(io, .fromMilliseconds(1), .awake);
                }
            }
            try std.testing.expect(found);
            self.client.?.evictChunk(self.layout.encodeChunkCoords(coords), token);
        }
    }
};

test "seeded public service saves recover exact acknowledged prefixes and discard unsaved suffixes" {
    for ([_]u64{ 7, 101, 20261019 }) |seed| {
        var harness: Harness = undefined;
        try harness.init(seed);
        defer harness.deinit();
        errdefer harness.printTrace();
        const current = try a.create(Model);
        defer a.destroy(current);
        current.init();
        const durable = try a.create(Model);
        defer a.destroy(durable);
        durable.* = current.*;
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..4) |round| {
            for (0..8) |_| try harness.edit(current, prng.random());
            current.tick = (round + 1) * 10;
            current.player = .{ .id = seed, .feet = .{ @floatFromInt(round + 1), 2.5, 0 }, .yaw = 0.25, .pitch = -0.1 };
            try harness.save(current, round % 2 == 1);
            durable.* = current.*;
            for (0..3) |_| try harness.edit(current, prng.random());
            // The saved player and logical clock must survive, not this newer suffix.
            harness.service.?.advanceTo(current.tick + 1);
            var unsaved_player = current.player.?;
            unsaved_player.feet[0] += 100;
            harness.client.?.publishCheckpoint(unsaved_player);
            try harness.restart(durable);
            current.* = durable.*;
        }
    }
}
