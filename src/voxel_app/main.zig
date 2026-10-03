const std = @import("std");
const math = std.math;
const zgpu = @import("engine").zgpu;
const wgpu = zgpu.wgpu;
const zgui = @import("engine").zgui;
const zglfw = @import("engine").zglfw;
const gltf_loader = @import("gltf_loader");
const content_dir = @import("build_options").content_dir;
const zmath = @import("zmath");

const debug = @import("debug");
const WindowContext = @import("engine").WindowContext;
const Engine = @import("engine").Engine;
const KeyParams = @import("engine").KeyParams;
const GameObject = @import("engine").GameObject;
const GameObjectGroup = @import("engine").GameObjectGroup;
const Scene = @import("engine").Scene;
const voxel_chunk_module = @import("engine").voxel_chunk;
const Side = @import("engine").voxel_chunk.Side;
const tube = @import("engine").tube;
const utils = @import("engine").utils;
const zgui_utils = @import("engine").zgui_utils;
const chunk_utils = @import("engine").chunk_utils;

const world_module = @import("world.zig");
const World = @import("world.zig").World;
const encodeChunkPosition = @import("world.zig").encodeChunkPosition;
const encodeChunkPositionArray = @import("world.zig").encodeChunkPositionArray;
const WorldChunk = @import("world.zig").WorldChunk;
const world_generator = @import("./world_generator.zig");
const world_data_service = @import("./world_data_service.zig");
const WorldDataService = world_data_service.WorldDataService;
const ChunkResponse = world_data_service.ChunkResponse;
const SimulationWorker = @import("./simulation_worker.zig").SimulationWorker;
const consts = @import("./consts.zig");
const world_engine = @import("./world_engine_glue.zig");

const DEBUG = true;

/// Chunks within this distance from the camera chunk are requested and uploaded to the GPU.
const CHUNK_LOAD_RADIUS = 2;
/// Chunks farther than this are evicted. Larger than `CHUNK_LOAD_RADIUS`, so moving back and
/// forth across a chunk border doesn't re-request the same chunks.
const CHUNK_KEEP_RADIUS = CHUNK_LOAD_RADIUS + 1;

const Game = struct {
    allocator: std.mem.Allocator,
    engine: *Engine,
    world: ?World = null,
    world_data: ?*WorldDataService = null,
    world_client: ?*world_data_service.Client = null,
    simulation: ?*SimulationWorker = null,
    /// Active subscriptions, including loads still in flight. Kept until cache eviction.
    chunk_subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    chunk_responses: std.ArrayList(ChunkResponse) = .empty,
    loaded_chunk_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    last_camera_chunk_coords: ?@Vector(4, i32) = null,
    saved_game_objects: std.StringHashMapUnmanaged(*GameObject) = .empty,
    saved_game_object_groups: std.StringHashMapUnmanaged(*GameObjectGroup) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Game {
        const game = try allocator.create(Game);
        game.* = .{
            .allocator = allocator,
            .engine = undefined,
        };
        return game;
    }

    pub fn deinit(game: *Game) void {
        if (game.simulation) |simulation| simulation.destroy();
        if (game.world_data) |world_data| {
            // Submit remaining local commands before the service drains its queue.
            game.flushBlockOperations();
            world_data.destroy();
        }
        game.chunk_subscriptions.deinit(game.allocator);
        for (game.chunk_responses.items) |response| response.chunk.content.deinit(game.allocator);
        game.chunk_responses.deinit(game.allocator);
        game.loaded_chunk_ids.deinit(game.allocator);

        game.saved_game_objects.deinit(game.allocator);
        game.saved_game_object_groups.deinit(game.allocator);
        if (game.world) |*world| {
            world.deinit();
        }
        game.engine.deinit();
        game.allocator.destroy(game);
    }

    pub fn updateWorld(game: *Game) void {
        if (game.world == null) {
            return;
        }

        game.flushBlockOperations();
        const has_new_chunks = game.receiveChunks();
        game.updateChunksAroundCamera(has_new_chunks);
    }

    /// Submit commands in optimistic edit order; no chunk data crosses in this direction.
    fn flushBlockOperations(game: *Game) void {
        const world = &game.world.?;
        for (world.pending_operations.items) |*pending| {
            if (pending.request_id == null) {
                pending.request_id = game.world_client.?.submitOperation(pending.operation);
            }
        }
    }

    /// Retire completed commands even when evicted; reconcile only active subscriptions.
    fn receiveChunks(game: *Game) bool {
        const world = &game.world.?;
        const responses = &game.chunk_responses;
        game.world_client.?.takeResponses(responses);
        defer responses.clearRetainingCapacity();

        var has_new_chunks = false;
        for (responses.items) |response| {
            if (response.operation) |result| {
                if (result.status != .success) {
                    std.debug.print("block operation {d} failed: {s}\n", .{ result.request_id, @tagName(result.status) });
                }
            }
            if (!applyChunkResponse(world, &game.chunk_subscriptions, response)) continue;
            const chunk_id = encodeChunkPositionArray(response.coords);
            // Invalidate GPU data for authoritative changes and optimistic rollbacks alike.
            game.removeChunkByIdIfNeeded(chunk_id);
            for (0..3) |axis| {
                for ([_]i32{ -1, 1 }) |offset| {
                    var neighbor = [3]i32{ response.coords[0], response.coords[1], response.coords[2] };
                    neighbor[axis] += offset;
                    if (normalizeChunkCoords(neighbor)) |coords| game.removeChunkIfNeeded(coords);
                }
            }
            has_new_chunks = true;
        }
        return has_new_chunks;
    }

    fn requestChunkRange(game: *Game, column: [2]u30, z_start: u30, z_end: u30) void {
        const request_id = game.world_client.?.requestChunks(column, z_start, z_end);

        var z = z_start;
        while (z < z_end) : (z += 1) {
            game.chunk_subscriptions.put(game.allocator, encodeChunkPosition(column[0], column[1], z), request_id) catch @panic("OOM");
        }
    }

    fn isChunkMissing(game: *const Game, coords: [3]u30) bool {
        return !game.world.?.hasChunk(coords) and
            !game.chunk_subscriptions.contains(encodeChunkPositionArray(coords));
    }

    /// Requests the missing chunks of the camera box, the closest columns first. Consecutive
    /// missing chunks of a column are requested together, so the column-wide part of the
    /// generation is done once for them.
    fn requestChunksAroundCamera(game: *Game, camera_chunk_coords: @Vector(4, i32)) void {
        const z_min = @max(camera_chunk_coords[2] - CHUNK_LOAD_RADIUS, 0);
        const z_max = @min(camera_chunk_coords[2] + CHUNK_LOAD_RADIUS, consts.WORLD_SIZE[2] - 1);

        var radius: i32 = 0;
        while (radius <= CHUNK_LOAD_RADIUS) : (radius += 1) {
            var dy = -radius;
            while (dy <= radius) : (dy += 1) {
                var dx = -radius;
                while (dx <= radius) : (dx += 1) {
                    if (@max(@abs(dx), @abs(dy)) != radius) {
                        continue;
                    }

                    const bottom_coords = normalizeChunkCoords(.{
                        camera_chunk_coords[0] + dx,
                        camera_chunk_coords[1] + dy,
                        0,
                    }) orelse continue;
                    forEachMissingChunkRange(z_min, z_max, MissingColumnChunks{
                        .game = game,
                        .column = .{ bottom_coords[0], bottom_coords[1] },
                    });
                }
            }
        }
    }

    const MissingColumnChunks = struct {
        game: *Game,
        column: [2]u30,

        fn isMissing(self: MissingColumnChunks, z: u30) bool {
            return self.game.isChunkMissing(.{ self.column[0], self.column[1], z });
        }

        fn onRange(self: MissingColumnChunks, z_start: u30, z_end: u30) void {
            self.game.requestChunkRange(self.column, z_start, z_end);
        }
    };

    /// Forgets the chunks (received or requested) that are too far from the camera.
    fn evictFarChunks(game: *Game, camera_chunk_coords: @Vector(4, i32)) void {
        const world = &game.world.?;

        // Preserve command ordering relative to eviction and subsequent re-subscription.
        game.flushBlockOperations();

        var far_chunk_ids: std.ArrayList(u32) = .empty;
        defer far_chunk_ids.deinit(game.allocator);

        var subscription_iterator = game.chunk_subscriptions.keyIterator();
        while (subscription_iterator.next()) |chunk_id| {
            if (getChunkDistance(chunk_id.*, camera_chunk_coords) > CHUNK_KEEP_RADIUS) {
                far_chunk_ids.append(game.allocator, chunk_id.*) catch @panic("OOM");
            }
        }
        for (far_chunk_ids.items) |chunk_id| {
            const subscription = game.chunk_subscriptions.fetchRemove(chunk_id).?;
            game.world_client.?.evictChunk(chunk_id, subscription.value);
            game.removeChunkByIdIfNeeded(chunk_id);
            const coords = world_module.decodeChunkPosition(chunk_id);
            if (world.hasChunk(coords)) world.removeChunk(coords);
        }
    }

    pub fn updateChunksAroundCamera(game: *Game, has_new_chunks: bool) void {
        const engine = game.engine;
        const voxel_grid = engine.active_scene.?.voxel_grid;

        const camera_position = engine.active_scene.?.camera.position;

        const camera_chunk_coords = chunk_utils.getChunkCoords(camera_position);

        const has_camera_moved = if (game.last_camera_chunk_coords) |last_camera_chunk_coords|
            !@reduce(.And, camera_chunk_coords == last_camera_chunk_coords)
        else
            true;

        if (!has_camera_moved and !has_new_chunks) {
            return;
        }

        const camera_box = fitBoxIntoWorld(getBoxAroundChunk(camera_chunk_coords, CHUNK_LOAD_RADIUS));

        if (has_camera_moved) {
            game.unloadChunksAwayFromCamera(camera_chunk_coords, camera_box);
            game.evictFarChunks(camera_chunk_coords);
            game.requestChunksAroundCamera(camera_chunk_coords);

            std.debug.print("camera_box: {any} <-> {any}\n", .{ camera_box.start, camera_box.end });
        }

        // Chunks that aren't received yet are skipped here and picked up by one of the next
        // calls, once new chunks arrive.
        // TODO: in case of small delta chunks, we can traverse only the plain along the movement direction
        var chunk_z = camera_box.start[2];
        while (chunk_z <= camera_box.end[2]) {
            var chunk_y = camera_box.start[1];
            while (chunk_y <= camera_box.end[1]) {
                var chunk_x = camera_box.start[0];
                while (chunk_x <= camera_box.end[0]) {
                    game.uploadChunkIfNeeded(chunk_x, chunk_y, chunk_z);

                    chunk_x += 1;
                }
                chunk_y += 1;
            }
            chunk_z += 1;
        }

        voxel_grid.uploadToGPU(engine.gctx);

        game.last_camera_chunk_coords = camera_chunk_coords;
    }

    fn unloadChunksAwayFromCamera(game: *Game, camera_chunk_coords: @Vector(4, i32), camera_box: ChunkBox) void {
        if (game.last_camera_chunk_coords) |last_camera_chunk_coords| {
            std.debug.print("DIFFING {any}\n", .{last_camera_chunk_coords});

            const delta_chunks = camera_chunk_coords - last_camera_chunk_coords;
            // if only 1 chunk shift (movement in adjacent chunk)
            const delta_chunks_abs = @abs(delta_chunks);
            if (@reduce(.Add, delta_chunks_abs) == 1) {
                std.debug.print("1 chunk shift\n", .{});
                // removing 4 chunks away chunks, keeping 3 chunks away
                const box = getBoxAroundChunk(camera_chunk_coords, 4);

                // yz plane
                if (delta_chunks_abs[0] == 1) {
                    // if the player moves x + 1, then we need to cleanup plane along x - 4
                    // (in backward direction)
                    const delta_x = -4 * delta_chunks[0];
                    const fixed_x = camera_chunk_coords[0] + delta_x;

                    var z = box.start[2];
                    while (z < box.end[2]) {
                        var y = box.start[1];
                        while (y < box.end[1]) {
                            if (normalizeChunkCoords(.{ fixed_x, y, z })) |pos| {
                                game.removeChunkIfNeeded(pos);
                            }
                            y += 1;
                        }
                        z += 1;
                    }
                    // xz plane
                } else if (delta_chunks_abs[1] == 1) {
                    const delta_y = -4 * delta_chunks[1];
                    const fixed_y = camera_chunk_coords[1] + delta_y;

                    var z = box.start[2];
                    while (z < box.end[2]) {
                        var x = box.start[0];
                        while (x < box.end[0]) {
                            if (normalizeChunkCoords(.{ x, fixed_y, z })) |pos| {
                                game.removeChunkIfNeeded(pos);
                            }
                            x += 1;
                        }
                        z += 1;
                    }
                } else {
                    // xy plane
                    const delta_z = -4 * delta_chunks[2];
                    const fixed_z = camera_chunk_coords[2] + delta_z;

                    var y = box.start[1];
                    while (y < box.end[1]) {
                        var x = box.start[0];
                        while (x < box.end[0]) {
                            if (normalizeChunkCoords(.{ x, y, fixed_z })) |pos| {
                                game.removeChunkIfNeeded(pos);
                            }
                            x += 1;
                        }
                        y += 1;
                    }
                }
            } else {
                // Mean that already loaded chunks are not overlapping with the new camera box
                if (@reduce(.Max, @abs(delta_chunks)) > 6) {
                    std.debug.print("full cleanup\n", .{});
                    // full cleanup
                    // TODO: In case of full cleanup, we can remove all loaded chunks by reseting
                    // buffers, instead of removing them one by one.
                    // var iterator = game.loaded_chunk_ids.keyIterator();
                    // while (iterator.next()) |chunk_id_ptr| {
                    //     const chunk_id = chunk_id_ptr.*;
                    //     game.removeChunkByIdIfNeeded(chunk_id);
                    // }
                    game.engine.active_scene.?.voxel_grid.clearChunks();
                    game.loaded_chunk_ids.clearRetainingCapacity();
                } else {
                    // intersection cleanup
                    std.debug.print("partial cleanup\n", .{});
                    var iterator = game.loaded_chunk_ids.keyIterator();
                    while (iterator.next()) |chunk_id_ptr| {
                        const chunk_id = chunk_id_ptr.*;
                        const chunk_coords = world_module.decodeChunkPositionVec(chunk_id);
                        if (!camera_box.isContainingChunk(chunk_coords)) {
                            game.removeChunkByIdIfNeeded(chunk_id);
                        }
                    }
                }
            }
        }
    }

    fn uploadChunkIfNeeded(game: *Game, chunk_x: i32, chunk_y: i32, chunk_z: i32) void {
        const voxel_grid = game.engine.active_scene.?.voxel_grid;
        const world = &game.world.?;

        const chunk_coords = world_module.normalizeChunkPosition(chunk_x, chunk_y, chunk_z);
        const chunk_id = encodeChunkPositionArray(chunk_coords);

        if (game.loaded_chunk_ids.contains(chunk_id)) {
            return;
        }

        const world_chunk = world.getChunk(chunk_coords) orelse return;
        if (world_chunk.content == .blocks) {
            voxel_grid.appendChunk(.{
                .chunk_coords = chunk_coords,
                // Can be used for testing:
                // .chunk_side_data = ChunkSideData.initWithTestData(game.allocator),
                .chunk_side_data = world_engine.extractChunkSideData(game.allocator, world_chunk.content.blocks),
            });

            if (DEBUG) {
                std.debug.print("appended chunk {any}\n", .{chunk_coords});
            }
        }

        game.loaded_chunk_ids.put(game.allocator, chunk_id, {}) catch @panic("OOM");
    }

    fn removeChunkIfNeeded(game: *Game, chunk_coords: [3]u30) void {
        game.removeChunkByIdIfNeeded(encodeChunkPositionArray(chunk_coords));
    }

    fn removeChunkByIdIfNeeded(game: *Game, chunk_id: u32) void {
        if (game.loaded_chunk_ids.contains(chunk_id)) {
            _ = game.loaded_chunk_ids.remove(chunk_id);
            game.engine.active_scene.?.voxel_grid.removeChunk(world_module.decodeChunkPosition(chunk_id));
        }
    }

    // TODO: will be refactored later, for now just draw all chunks
    // fn checkIfChunkCanBeSkipped(game: *Game, chunk_coords: [3]u30) bool {
    //     const surrounding_chunks = getSurroundingChunks(&game.world.?, chunk_coords);
    //
    //     for (surrounding_chunks, 0..) |surrounding_chunk_opt, side_index| {
    //         // out of world bounds, nothing can be seen from there
    //         const surrounding_chunk = surrounding_chunk_opt orelse continue;
    //
    //         const side = @as(Side, @enumFromInt(side_index));
    //         if (!surrounding_chunk.flags.getSideSolidness(side.getOpposite())) {
    //             return false;
    //         }
    //     }
    //     return true;
    // }

    fn editBlockUnderCamera(game: *Game, action: BlockAction) void {
        const world = if (game.world) |*world| world else return;

        const camera_position = game.engine.active_scene.?.camera.position;
        const top = getColumnTopUnderPosition(camera_position) orelse return;

        const edit_result = switch (action) {
            .remove => world.removeTopBlockInColumn(top),
            .add_dirt => world.dropBlockInColumn(top, .dirt),
        };
        // Chunks near the camera are normally received, so this happens only while they are
        // still loading, or when the column has to be searched too far from the camera.
        const edited_block = edit_result catch |err| switch (err) {
            error.ChunkNotReceived => {
                if (DEBUG) {
                    std.debug.print("can't {s} block under {any}, chunks aren't received yet\n", .{ @tagName(action), top });
                }
                return;
            },
        } orelse return;

        if (DEBUG) {
            std.debug.print("{s} block {any}\n", .{ @tagName(action), edited_block });
        }

        game.reloadChunksAroundBlock(edited_block);
    }

    /// Re-uploads the chunk of the edited block and the neighbor chunks sharing a face with it,
    /// because their visibility depends on the solidness of the chunk sides.
    fn reloadChunksAroundBlock(game: *Game, block: [3]u32) void {
        const chunk_coords, const local = world_module.splitBlockCoords(block);

        game.reloadChunkIfLoaded(chunk_coords);

        for (0..3) |axis| {
            const offset: i32 = switch (local[axis]) {
                0 => -1,
                consts.CHUNK_SIZE - 1 => 1,
                else => continue,
            };

            var neighbor_coords_i = [3]i32{ chunk_coords[0], chunk_coords[1], chunk_coords[2] };
            neighbor_coords_i[axis] += offset;
            const neighbor_coords = normalizeChunkCoords(neighbor_coords_i) orelse continue;
            game.reloadChunkIfLoaded(neighbor_coords);
        }

        game.engine.active_scene.?.voxel_grid.uploadToGPU(game.engine.gctx);
    }

    fn reloadChunkIfLoaded(game: *Game, chunk_coords: [3]u30) void {
        const chunk_id = encodeChunkPositionArray(chunk_coords);
        if (!game.loaded_chunk_ids.contains(chunk_id)) {
            return;
        }

        game.removeChunkByIdIfNeeded(chunk_id);
        game.uploadChunkIfNeeded(chunk_coords[0], chunk_coords[1], chunk_coords[2]);
    }
};

/// Consumes the response, including stale and evicted snapshots. Acknowledgements are
/// independent of subscription lifetime so pending edits can always be retired.
fn applyChunkResponse(world: *World, subscriptions: *const std.AutoHashMapUnmanaged(u32, u64), response: ChunkResponse) bool {
    if (response.operation) |result| world.acknowledgeOperation(result.request_id);
    const token = subscriptions.get(encodeChunkPositionArray(response.coords));
    if (token == null or token != response.subscription_id) {
        response.chunk.content.deinit(world.allocator);
        return false;
    }
    world.insertChunk(response.coords, response.chunk) catch {
        response.chunk.content.deinit(world.allocator);
        return false;
    };
    return true;
}

const BlockAction = enum {
    remove,
    add_dirt,
};

/// Returns the block containing `position`, clamped to the top of the world.
/// Returns null if the position is outside of the world (or below its bottom).
fn getColumnTopUnderPosition(position: [3]f32) ?[3]u32 {
    var block: [3]i64 = undefined;
    for (0..3) |axis| {
        block[axis] = @as(i64, @intFromFloat(@floor(position[axis]))) +
            @as(i64, consts.WORLD_ORIGIN[axis]) * consts.CHUNK_SIZE;
    }

    const world_size = consts.WORLD_SIZE_IN_BLOCKS;

    if (block[1] < 0 or block[1] >= world_size[1] or block[2] < 0) {
        return null;
    }

    return .{
        @intCast(@mod(block[0], world_size[0])),
        @intCast(block[1]),
        @intCast(@min(block[2], world_size[2] - 1)),
    };
}

fn initWorld(game: *Game) !void {
    game.world_data = try WorldDataService.create(game.engine.io, game.allocator, .{ .terrain = .{ .seed = 12345 } });
    game.world = World.init(game.allocator);
    game.world_client = try game.world_data.?.createClient();
    game.simulation = try SimulationWorker.create(game.world_data.?);
}

/// Chebyshev distance between the chunk and the camera chunk, in chunks. The x axis wraps.
fn getChunkDistance(chunk_id: u32, camera_chunk_coords: @Vector(4, i32)) i32 {
    const coords = world_module.decodeChunkPosition(chunk_id);
    const world_width: i32 = consts.WORLD_SIZE[0];

    const dx = @mod(@as(i32, coords[0]) - camera_chunk_coords[0], world_width);
    const dy: i32 = @intCast(@abs(@as(i32, coords[1]) - camera_chunk_coords[1]));
    const dz: i32 = @intCast(@abs(@as(i32, coords[2]) - camera_chunk_coords[2]));

    return @max(@min(dx, world_width - dx), dy, dz);
}

/// Calls `context.onRange(z_start, z_end)` for every range [z_start, z_end) of consecutive z
/// in [z_min, z_max] for which `context.isMissing(z)` is true. Does nothing if z_min > z_max.
fn forEachMissingChunkRange(z_min: i32, z_max: i32, context: anytype) void {
    var range_start: ?u30 = null;
    var z = z_min;
    while (z <= z_max + 1) : (z += 1) {
        const is_missing = z <= z_max and context.isMissing(@intCast(z));
        if (is_missing) {
            range_start = range_start orelse @intCast(z);
        } else if (range_start) |start| {
            context.onRange(start, @intCast(z));
            range_start = null;
        }
    }
}

pub fn normalizeChunkCoords(coords_in: [3]i32) ?[3]u30 {
    var coords = coords_in;

    if (coords[0] < 0) {
        coords[0] += consts.WORLD_SIZE[0];
    } else if (coords[0] >= consts.WORLD_SIZE[0]) {
        coords[0] -= consts.WORLD_SIZE[0];
    }

    if (coords[1] < 0 or coords[1] >= consts.WORLD_SIZE[1]) {
        return null;
    }

    if (coords[2] < 0 or coords[2] >= consts.WORLD_SIZE[2]) {
        return null;
    }

    return .{
        @intCast(coords[0]),
        @intCast(coords[1]),
        @intCast(coords[2]),
    };
}

/// Returns neighbors indexed by `Side`, `null` items are out of world bounds.
/// Returns null if any of the neighbors isn't received from the world-data thread yet.
fn getSurroundingChunks(world: *const World, coords: [3]u30) ?[6]?WorldChunk {
    const coords_i = [3]i32{ @intCast(coords[0]), @intCast(coords[1]), @intCast(coords[2]) };

    const neighbors = [_]struct { Side, [3]i32 }{
        .{ .left, .{ coords_i[0] - 1, coords_i[1], coords_i[2] } },
        .{ .right, .{ coords_i[0] + 1, coords_i[1], coords_i[2] } },
        .{ .back, .{ coords_i[0], coords_i[1] + 1, coords_i[2] } },
        .{ .front, .{ coords_i[0], coords_i[1] - 1, coords_i[2] } },
        .{ .bottom, .{ coords_i[0], coords_i[1], coords_i[2] - 1 } },
        .{ .top, .{ coords_i[0], coords_i[1], coords_i[2] + 1 } },
    };

    var resulting_chunks: [6]?WorldChunk = @splat(null);
    for (neighbors) |neighbor| {
        const side, const neighbor_coords = neighbor;
        if (normalizeChunkCoords(neighbor_coords)) |normalized_coords| {
            resulting_chunks[@intFromEnum(side)] = world.getChunk(normalized_coords) orelse return null;
        }
    }

    return resulting_chunks;
}

const ChunkBox = struct {
    start: @Vector(4, i32),
    end: @Vector(4, i32), // end is inclusive

    pub fn isContainingChunk(self: *const ChunkBox, chunk: @Vector(4, i32)) bool {
        return @reduce(.And, chunk >= self.start) and
            @reduce(.And, chunk <= self.end);
    }
};

fn getBoxAroundChunk(chunk_coords: @Vector(4, i32), radius: i32) ChunkBox {
    const delta = @Vector(4, i32){ radius, radius, radius, 0 };
    return .{
        .start = chunk_coords - delta,
        .end = chunk_coords + delta,
    };
}

fn fitBoxIntoWorld(box: ChunkBox) ChunkBox {
    return .{
        // x-axis wraps around the world (so no min/max needed)
        // box.start[0] = box.start[0];
        // box.start[1] = @max(0, box.start[1]);
        // box.start[2] = @max(0, box.start[2]);
        .start = @max(box.start, @Vector(4, i32){
            std.math.minInt(i32),
            0,
            0,
            0,
        }),
        // x-axis wraps around the world (so no min/max needed)
        // box.end[0] = box.end[0];
        // box.end[1] = @min(consts.WORLD_SIZE[1], box.end[1]);
        // box.end[2] = @min(consts.WORLD_SIZE[2], box.end[2]);
        .end = @min(box.end, @Vector(4, i32){
            std.math.maxInt(i32),
            consts.WORLD_SIZE[1] - 1,
            consts.WORLD_SIZE[2] - 1,
            0,
        }),
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Change current working directory to where the executable is located.
    {
        const path = std.process.executableDirPathAlloc(init.io, allocator) catch ".";
        defer allocator.free(path);
        const pathz = try allocator.dupeZ(u8, path);
        defer allocator.free(pathz);
        const result = std.posix.system.chdir(pathz);
        if (result != 0) {
            std.debug.print("Failed to change directory to {s}: {}\n", .{ pathz, result });
            // ignoring error and trying to continue work in the current directory
        }
    }

    var window_context = try WindowContext.init(allocator);
    defer window_context.deinit();

    const game: *Game = try .init(allocator);
    defer game.deinit();

    const engine = Engine.init(
        init.io,
        allocator,
        .{
            .window_context = window_context,
            .content_dir = content_dir,
            .zgui = true,
        },
        .{
            .argument = game,
            .onUpdate = onUpdate,
            .onRender = onRender,
            .onKeyPress = onKeyPress,
        },
    );
    game.engine = engine;

    const man_model_id = id: {
        const loader = try engine.initLoader("man/man.gltf");
        defer loader.deinit();

        const object = loader.findFirstObjectWithMesh().?;
        break :id try engine.loadModel(&loader, object, .{
            .mesh_y_up = true,
            .animations = &.{"walkLikeMan"},
        });
    };

    const scene = try engine.createScene();
    defer scene.deinit();

    scene.camera.updatePosition(.{ -2.06, -2.96, 8.45 });
    // edge of the world:
    // scene.camera.updatePosition(.{ -8192.0, -4096.0, 0 });

    // -- Skybox (old) --

    // const skybox_model = try engine.loadSkyBoxModel("skybox/cubemaps_skybox.png");
    // defer skybox_model.deinit(engine.gctx);
    // defer allocator.destroy(skybox_model);

    // _ = try scene.addSkyBoxObject(.{
    //     .model = skybox_model,
    // });

    // -- Skybox (cubemap) --

    const skybox_cubemap_model = try engine.loadSkyBoxCubemapModel(.{
        "skybox/skybox/right.jpg",
        "skybox/skybox/left.jpg",
        "skybox/skybox/top.jpg",
        "skybox/skybox/bottom.jpg",
        "skybox/skybox/front.jpg",
        "skybox/skybox/back.jpg",
    });
    defer skybox_cubemap_model.deinit(engine.gctx);
    defer allocator.destroy(skybox_cubemap_model);

    _ = try scene.setSkyBoxCubemapObject(.{
        .model = skybox_cubemap_model,
    });

    // ---

    var window_block_model = try engine.loadWindowBoxModel("window-block/wb-texture.png");
    // TODO: Move cleanup to the engine
    defer {
        window_block_model.deinit(engine.gctx);
        allocator.destroy(window_block_model);
    }

    // _ = man_model_id;
    try game.saved_game_objects.put(allocator, "man_1", try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ -2, 0, 6 },
        .parent = null,
        .animation_name = "walkLikeMan",
    }));

    try game.saved_game_objects.put(allocator, "man_2", try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ 4, 0, 8 },
        .parent = null,
        .animation_name = "walkLikeMan",
    }));

    try initWorld(game);

    // -- Tube data for coordinates --

    var tube_data = try tube.initUnitTube(allocator);
    defer tube_data.deinit(allocator);
    var tube_model = try engine.loadPrimitive(tube_data);
    defer {
        tube_model.deinit(engine.gctx);
        allocator.destroy(tube_model);
    }

    // -- Coordinates --

    {
        const group = try scene.addGroup();
        errdefer group.deinit();

        try game.saved_game_object_groups.put(allocator, "coordinates", group);

        group.setPosition(.{ 0, 0, 0, 0 });

        const tube_x = try scene.addPrimitiveObject(.{
            .model = tube_model,
            .position = .{ 0.5 + tube.M, 0, 0 },
        });
        tube_x.debug.color = .{ 1, 0, 0, 1 };

        const tube_y = try scene.addPrimitiveObject(.{
            .model = tube_model,
            .position = .{ 0, 0.5 + tube.M, 0 },
        });
        tube_y.setRotation(zmath.quatFromAxisAngle(.{ 0, 0, 1, 0 }, math.pi / 2.0));
        tube_y.debug.color = .{ 0, 1, 0, 1 };

        const tube_z = try scene.addPrimitiveObject(.{
            .model = tube_model,
            .position = .{ 0, 0, 0.5 + tube.M },
        });
        tube_z.setRotation(zmath.quatFromAxisAngle(.{ 0, 1, 0, 0 }, math.pi / 2.0));
        tube_z.debug.color = .{ 0, 0, 1, 1 };

        try group.addObject(tube_x);
        try group.addObject(tube_y);
        try group.addObject(tube_z);
    }

    // -- Light --

    try scene.addDirectionalLight(.{
        .direction = zmath.normalize3(zmath.Vec{ 0.2, 0.3, -1, 1 }),
        .color = .{ 1, 1, 1, 1 },
        .intensity = 1.0,
    });

    // -- ZGui --

    zgui_utils.zguiInit(allocator, window_context.window, engine.gctx.device, content_dir);
    defer zgui_utils.zguiDeinit();

    // -- Game loop --

    try engine.runLoop();
}

fn onUpdate(engine: *Engine, game_opaque: *anyopaque) void {
    const game: *Game = @ptrCast(@alignCast(game_opaque));

    if (game.saved_game_objects.get("man_1")) |obj| {
        obj.setRotation(zmath.quatFromRollPitchYaw(0, 0, @floatCast(engine.time)));
    }
    if (game.saved_game_objects.get("man_2")) |obj| {
        obj.setRotation(zmath.quatFromRollPitchYaw(0, 0, @floatCast(-engine.time)));
    }
    // if (game.saved_game_object_groups.get("coordinates")) |group| {
    //     group.setPosition(.{ 0, 0, @floatCast(math.sin(engine.time) * 10), 0 });
    // }

    game.updateWorld();
}

fn onKeyPress(engine: *Engine, key_params: KeyParams, game_opaque: *anyopaque) void {
    _ = engine;
    const game: *Game = @ptrCast(@alignCast(game_opaque));

    switch (key_params.key) {
        .x => game.editBlockUnderCamera(.remove),
        .z => game.editBlockUnderCamera(.add_dirt),
        else => {},
    }
}

fn onRender(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    _ = engine;
    _ = pass;
    _ = game_opaque;
}

test {
    _ = world_module;
    _ = world_generator;
    _ = world_data_service;
    _ = SimulationWorker;
}

test "chunk distance is the largest axis distance and wraps around x" {
    const camera = @Vector(4, i32){ 0, 10, 2, 0 };
    const world_width: i32 = consts.WORLD_SIZE[0];

    try std.testing.expectEqual(0, getChunkDistance(encodeChunkPosition(0, 10, 2), camera));
    try std.testing.expectEqual(3, getChunkDistance(encodeChunkPosition(3, 10, 2), camera));
    try std.testing.expectEqual(1, getChunkDistance(encodeChunkPosition(consts.WORLD_SIZE[0] - 1, 10, 2), camera));
    try std.testing.expectEqual(1, getChunkDistance(encodeChunkPosition(0, 10, 2), .{ world_width - 1, 10, 2, 0 }));
    try std.testing.expectEqual(1, getChunkDistance(encodeChunkPosition(0, 10, 2), .{ -1, 10, 2, 0 }));
    try std.testing.expectEqual(world_width / 2, getChunkDistance(encodeChunkPosition(consts.WORLD_SIZE[0] / 2, 10, 2), camera));

    try std.testing.expectEqual(4, getChunkDistance(encodeChunkPosition(1, 6, 2), camera));
    try std.testing.expectEqual(10, getChunkDistance(encodeChunkPosition(0, 0, 2), camera));
    try std.testing.expectEqual(consts.WORLD_SIZE[1] - 1 - 10, getChunkDistance(encodeChunkPosition(0, consts.WORLD_SIZE[1] - 1, 2), camera));
    try std.testing.expectEqual(2, getChunkDistance(encodeChunkPosition(1, 11, 0), camera));
    try std.testing.expectEqual(consts.WORLD_SIZE[2] - 1 - 2, getChunkDistance(encodeChunkPosition(1, 11, consts.WORLD_SIZE[2] - 1), camera));
}

test "chunk coords wrap around x and are out of the world beyond y and z" {
    const width: i32 = consts.WORLD_SIZE[0];
    const depth: i32 = consts.WORLD_SIZE[1];
    const height: i32 = consts.WORLD_SIZE[2];

    try std.testing.expectEqual([3]u30{ 1, 2, 3 }, normalizeChunkCoords(.{ 1, 2, 3 }).?);
    try std.testing.expectEqual([3]u30{ consts.WORLD_SIZE[0] - 1, 0, 0 }, normalizeChunkCoords(.{ -1, 0, 0 }).?);
    try std.testing.expectEqual([3]u30{ 0, consts.WORLD_SIZE[1] - 1, consts.WORLD_SIZE[2] - 1 }, normalizeChunkCoords(.{ width, depth - 1, height - 1 }).?);
    try std.testing.expectEqual(null, normalizeChunkCoords(.{ 0, -1, 0 }));
    try std.testing.expectEqual(null, normalizeChunkCoords(.{ 0, depth, 0 }));
    try std.testing.expectEqual(null, normalizeChunkCoords(.{ 0, 0, -1 }));
    try std.testing.expectEqual(null, normalizeChunkCoords(.{ 0, 0, height }));
}

test "box around a chunk is clamped to the world along y and z only" {
    const box = fitBoxIntoWorld(getBoxAroundChunk(.{ 0, 1, consts.WORLD_SIZE[2] - 1, 0 }, 2));
    try std.testing.expectEqual(@Vector(4, i32){ -2, 0, consts.WORLD_SIZE[2] - 3, 0 }, box.start);
    try std.testing.expectEqual(@Vector(4, i32){ 2, 3, consts.WORLD_SIZE[2] - 1, 0 }, box.end);
    try std.testing.expect(box.isContainingChunk(.{ -2, 0, consts.WORLD_SIZE[2] - 1, 0 }));
    try std.testing.expect(!box.isContainingChunk(.{ 3, 0, consts.WORLD_SIZE[2] - 1, 0 }));
}

test "column top under a position is clamped to the top of the world" {
    const origin = [3]u32{
        consts.WORLD_ORIGIN[0] * consts.CHUNK_SIZE,
        consts.WORLD_ORIGIN[1] * consts.CHUNK_SIZE,
        consts.WORLD_ORIGIN[2] * consts.CHUNK_SIZE,
    };
    const world_size = consts.WORLD_SIZE_IN_BLOCKS;

    try std.testing.expectEqual(origin, getColumnTopUnderPosition(.{ 0.5, 0.5, 0.5 }).?);
    try std.testing.expectEqual([3]u32{ origin[0] - 1, origin[1] - 1, origin[2] - 1 }, getColumnTopUnderPosition(.{ -0.5, -0.5, -0.5 }).?);
    try std.testing.expectEqual([3]u32{ origin[0], origin[1], world_size[2] - 1 }, getColumnTopUnderPosition(.{ 0, 0, 1.0e6 }).?);
    try std.testing.expectEqual([3]u32{ world_size[0] - 1, origin[1], origin[2] }, getColumnTopUnderPosition(.{ -@as(f32, @floatFromInt(origin[0])) - 1, 0, 0 }).?);
    try std.testing.expectEqual(null, getColumnTopUnderPosition(.{ 0, 0, -@as(f32, @floatFromInt(origin[2])) - 1 }));
    try std.testing.expectEqual(null, getColumnTopUnderPosition(.{ 0, @floatFromInt(world_size[1]), 0 }));
}

const TestColumn = struct {
    is_missing: []const bool,
    ranges: std.ArrayList([2]u30) = .empty,

    fn isMissing(self: *const TestColumn, z: u30) bool {
        return self.is_missing[z];
    }

    fn onRange(self: *TestColumn, z_start: u30, z_end: u30) void {
        self.ranges.append(std.testing.allocator, .{ z_start, z_end }) catch @panic("OOM");
    }
};

fn expectMissingChunkRanges(expected: []const [2]u30, z_min: i32, z_max: i32, is_missing: []const bool) !void {
    var column = TestColumn{ .is_missing = is_missing };
    defer column.ranges.deinit(std.testing.allocator);

    forEachMissingChunkRange(z_min, z_max, &column);
    try std.testing.expectEqualSlices([2]u30, expected, column.ranges.items);
}

test "missing chunks of a column are split into ranges of consecutive chunks" {
    const height = consts.WORLD_SIZE[2];
    const all_missing: [height]bool = @splat(true);
    const none_missing: [height]bool = @splat(false);

    try expectMissingChunkRanges(&.{.{ 0, height }}, 0, height - 1, &all_missing);
    try expectMissingChunkRanges(&.{.{ 1, 3 }}, 1, 2, &all_missing);
    try expectMissingChunkRanges(&.{}, 0, height - 1, &none_missing);

    var with_gaps = all_missing;
    with_gaps[0] = false;
    with_gaps[2] = false;
    with_gaps[3] = false;
    try expectMissingChunkRanges(&.{ .{ 1, 2 }, .{ 4, height } }, 0, height - 1, &with_gaps);
    try expectMissingChunkRanges(&.{.{ 1, 2 }}, 0, 3, &with_gaps);

    var only_top = none_missing;
    only_top[height - 1] = true;
    try expectMissingChunkRanges(&.{.{ height - 1, height }}, 0, height - 1, &only_top);
}

test "camera outside of the world height has no chunks to request" {
    const all_missing: [consts.WORLD_SIZE[2]]bool = @splat(true);

    try expectMissingChunkRanges(&.{}, 0, -3, &all_missing);
    try expectMissingChunkRanges(&.{}, consts.WORLD_SIZE[2] + 2, consts.WORLD_SIZE[2] - 1, &all_missing);
}

test "evicted edit replies retire pending work without restoring chunks" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer subscriptions.deinit(std.testing.allocator);
    const coords = [3]u30{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 0, 0, 0 }, .dirt);
    world.pending_operations.items[0].request_id = 7;
    world.removeChunk(coords);
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .operation = .{ .request_id = 7, .status = .already_exists },
        .chunk = WorldChunk.initEmpty(),
    }));
    try std.testing.expect(!world.hasChunk(coords));
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    // A response without a subscription must never be accepted just because both are null.
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = null,
        .chunk = WorldChunk.initEmpty(),
    }));
}

test "new subscription rejects queued snapshots from an evicted generation" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer subscriptions.deinit(std.testing.allocator);
    const coords = [3]u30{ 0, 0, 0 };
    try subscriptions.put(std.testing.allocator, encodeChunkPositionArray(coords), 2);
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .chunk = WorldChunk.initEmpty(),
    }));
    try std.testing.expect(applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 2,
        .chunk = WorldChunk.initEmpty(),
    }));
    var update = WorldChunk.initEmpty();
    _ = update.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .dirt });
    update.revision = 1;
    try std.testing.expect(applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 2,
        .chunk = update,
    }));
    try std.testing.expect(try world.isBlockSolid(.{ 1, 2, 3 }));
    try std.testing.expectEqual(2, subscriptions.get(encodeChunkPositionArray(coords)));
}
