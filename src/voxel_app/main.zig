const ChunkCoords = @import("engine").ChunkCoords;
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
const Position = @import("engine").world_math.Position;

const world_module = @import("world.zig");
const World = @import("world.zig").World;
const WorldLayout = @import("engine").WorldLayout;
const test_layout = @import("test_world.zig").layout;
const WorldChunk = @import("world.zig").WorldChunk;
const world_generator = @import("./world_generator.zig");
const world_data_service = @import("./world_data_service.zig");
const WorldDataService = world_data_service.WorldDataService;
const ChunkResponse = world_data_service.ChunkResponse;
const SimulationWorker = @import("./simulation_worker.zig").SimulationWorker;
const consts = @import("./consts.zig");
const world_engine = @import("./world_engine_glue.zig");

const DEBUG = true;

/// Chunks within this distance are requested; reachable chunks are uploaded to the GPU.
const CHUNK_LOAD_RADIUS = 3;
const BLOCK_LOAD_RADIUS = 1;
const TOOL_REACH: f64 = 20;

const Game = struct {
    const MeshVersion = struct { chunk_revision: u32, mesh_revision: u64 };
    const BoundarySnapshot = struct { masks: world_engine.BoundaryMasks, mesh_revision: u64 };
    allocator: std.mem.Allocator,
    engine: *Engine,
    world: ?World = null,
    world_data: ?*WorldDataService = null,
    world_client: ?*world_data_service.Client = null,
    simulation: ?*SimulationWorker = null,
    /// Active subscriptions, including loads still in flight. Kept until cache eviction.
    chunk_subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    chunk_packages: std.ArrayList(world_data_service.ResponsePackage) = .empty,
    chunk_modes: std.AutoHashMapUnmanaged(u32, world_data_service.Representation) = .empty,
    /// Metadata only: CPU mesh arrays transfer directly to the GPU upload queue.
    mesh_versions: std.AutoHashMapUnmanaged(u32, MeshVersion) = .empty,
    /// Authoritative fallback planes for block subscriptions, including retained demotions.
    boundary_snapshots: std.AutoHashMapUnmanaged(u32, BoundarySnapshot) = .empty,
    pinned_chunks: std.AutoHashMapUnmanaged(u32, void) = .empty,
    render_radius: i32 = CHUNK_LOAD_RADIUS,
    gpu_capacity_warning: bool = false,

    loaded_chunk_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Loaded chunks whose meshes must be rebuilt at the end of this frame's world update.
    dirty_chunk_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    last_camera_chunk_coords: ?ChunkCoords = null,
    saved_game_objects: std.StringHashMapUnmanaged(*GameObject) = .empty,
    saved_game_object_groups: std.StringHashMapUnmanaged(*GameObjectGroup) = .empty,

    fn layout(game: *const Game) *const WorldLayout {
        return game.world.?.layout;
    }

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
        for (game.chunk_packages.items) |*package| package.deinit(game.allocator);
        game.chunk_packages.deinit(game.allocator);
        game.chunk_modes.deinit(game.allocator);
        game.mesh_versions.deinit(game.allocator);
        game.boundary_snapshots.deinit(game.allocator);
        game.pinned_chunks.deinit(game.allocator);
        game.loaded_chunk_ids.deinit(game.allocator);
        game.dirty_chunk_ids.deinit(game.allocator);

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
        game.updateChunksAroundCamera(false);
        const has_new_chunks = game.receiveChunks();
        game.updateChunksAroundCamera(has_new_chunks);
        game.rebuildDirtyChunks();
        const grid = game.engine.active_scene.?.voxel_grid;
        if (!grid.hasUploadCapacity() and game.render_radius > 2) {
            std.debug.print("voxel buffer capacity reached; reducing the visible box to 5x5x5\n", .{});
            game.render_radius = 2;
            game.updateChunksAroundCamera(false);
        }
        if (!grid.hasUploadCapacity()) {
            if (!game.gpu_capacity_warning) std.debug.print("voxel uploads exceed buffer capacity even at 5x5x5; retaining pending uploads\n", .{});
            game.gpu_capacity_warning = true;
            return;
        }
        game.gpu_capacity_warning = false;
        grid.uploadToGPU(game.engine.gctx);
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

    /// A package is consumed in full before any mesh rebuild or GPU upload. Retire all
    /// acknowledgments first, then replay only commands not represented by these snapshots.
    fn receiveChunks(game: *Game) bool {
        game.world_client.?.takePackages(&game.chunk_packages);
        defer game.chunk_packages.clearRetainingCapacity();
        var changed = false;
        for (game.chunk_packages.items) |*package| {
            game.applyPackage(package);
            package.responses.deinit(game.allocator);
            changed = true;
        }
        return changed;
    }

    fn applyPackage(game: *Game, package: *world_data_service.ResponsePackage) void {
        const world = &game.world.?;
        for (package.responses.items) |response| {
            if (response.operation) |result| {
                world.acknowledgeOperation(result.request_id);
                if (result.status != .success) std.debug.print("block operation {d} failed: {s}\n", .{ result.request_id, @tagName(result.status) });
            }
        }
        for (package.responses.items) |response| {
            const id = game.layout().encodeChunkCoords(response.coords);
            const token = game.chunk_subscriptions.get(id);
            if (token == null or token != response.subscription_id) {
                response.deinit(game.allocator);
                continue;
            }
            switch (response.data) {
                .acknowledgement => {},
                .blocks => |snapshot| {
                    if ((game.chunk_modes.get(id) orelse .blocks) != .blocks) {
                        response.deinit(game.allocator);
                        continue;
                    }
                    world.insertChunk(response.coords, snapshot.chunk) catch {
                        response.deinit(game.allocator);
                        continue;
                    };
                    game.loadChunkIfNeeded(response.coords[0], response.coords[1], response.coords[2]);
                    if (snapshot.neighbors) |masks| game.installBoundaries(response.coords, masks, response.mesh_revision);
                    game.markChunkAndNeighborsDirty(response.coords);
                },
                .boundaries => |masks| {
                    if (game.chunk_modes.get(id) != .blocks) continue;
                    game.installBoundaries(response.coords, masks, response.mesh_revision);
                },
                .mesh, .unreachable_chunk => {
                    if (game.chunk_modes.get(id) != .mesh) {
                        response.deinit(game.allocator);
                        continue;
                    }
                    if (game.mesh_versions.get(id)) |old| {
                        if (response.mesh_revision < old.mesh_revision) {
                            response.deinit(game.allocator);
                            continue;
                        }
                    }
                    game.engine.active_scene.?.voxel_grid.removeChunk(response.coords);
                    if (response.data == .mesh) {
                        game.engine.active_scene.?.voxel_grid.appendChunk(.{ .chunk_coords = response.coords, .chunk_side_data = response.data.mesh });
                    }
                    game.loaded_chunk_ids.put(game.allocator, id, {}) catch @panic("OOM");
                    game.mesh_versions.put(game.allocator, id, .{ .chunk_revision = response.chunk_revision, .mesh_revision = response.mesh_revision }) catch @panic("OOM");
                    _ = game.dirty_chunk_ids.remove(id);
                    if (world.hasChunk(response.coords)) {
                        world.removeChunk(response.coords);
                        game.markChunkAndNeighborsDirty(response.coords);
                        _ = game.dirty_chunk_ids.remove(id);
                    }
                    _ = game.boundary_snapshots.remove(id);
                },
            }
        }
        // Reuse only an authoritative mesh certified by the final block snapshot and with
        // no outstanding local edit in any of its face dependencies.
        for (package.responses.items) |response| {
            if (response.data != .blocks) continue;
            const id = game.layout().encodeChunkCoords(response.coords);
            const token = game.chunk_subscriptions.get(id);
            if (token == null or token != response.subscription_id or (game.chunk_modes.get(id) orelse .blocks) != .blocks) continue;
            const chunk = world.getChunk(response.coords) orelse continue;
            const installed = game.mesh_versions.get(id) orelse continue;
            if (game.boundary_snapshots.get(id)) |boundary| {
                if (boundary.mesh_revision != response.mesh_revision) continue;
            }
            if (chunk.chunk_revision == response.chunk_revision and
                installed.chunk_revision == response.chunk_revision and installed.mesh_revision == response.mesh_revision and
                !world.hasPendingMeshDependency(response.coords))
                _ = game.dirty_chunk_ids.remove(id);
        }
    }

    fn installBoundaries(game: *Game, coords: ChunkCoords, masks: world_engine.BoundaryMasks, revision: u64) void {
        const id = game.layout().encodeChunkCoords(coords);
        if (game.boundary_snapshots.getPtr(id)) |old| {
            if (revision < old.mesh_revision) return;
            old.mesh_revision = revision;
            if (std.meta.eql(old.masks, masks)) return;
            const previous = old.masks;
            old.masks = masks;
            // Keep every accepted plane for future edits and handoffs, even when no
            // currently rendered boundary face depends on the changed occupancy.
            if (!game.boundaryVisibilityChanged(coords, previous, masks)) return;
        } else {
            game.boundary_snapshots.put(game.allocator, id, .{ .masks = masks, .mesh_revision = revision }) catch @panic("OOM");
        }
        game.markChunkDirtyIfLoaded(coords);
    }

    fn boundaryVisibilityChanged(game: *const Game, coords: ChunkCoords, previous: world_engine.BoundaryMasks, updated: world_engine.BoundaryMasks) bool {
        // A promotion can retain a service mesh before its blocks arrive. Without
        // those blocks, keep invalidation conservative until the snapshot certifies it.
        const chunk = game.world.?.chunks.getPtr(game.layout().encodeChunkCoords(coords)) orelse return true;
        if (chunk.flags.is_unreachable) return false;
        for (std.enums.values(Side)) |side| {
            if (game.localMeshNeighbor(coords, side) != null) continue;
            const i = @intFromEnum(side);
            for (chunk.boundaries[i].rows, previous[i].rows, updated[i].rows) |own, before, after| {
                if (own & (before ^ after) != 0) return true;
            }
        }
        return false;
    }

    fn requestChunkMode(game: *Game, coords: ChunkCoords, mode: world_data_service.Representation) void {
        const id = game.layout().encodeChunkCoords(coords);
        if (game.chunk_subscriptions.contains(id) and game.chunk_modes.get(id) == mode) return;
        const token = game.world_client.?.requestChunksInMode(.{ coords[0], coords[1] }, coords[2], coords[2] + 1, mode);
        game.chunk_subscriptions.put(game.allocator, id, token) catch @panic("OOM");
        game.chunk_modes.put(game.allocator, id, mode) catch @panic("OOM");
    }

    fn wantsBlocks(game: *const Game, coords: ChunkCoords) bool {
        const id = game.layout().encodeChunkCoords(coords);
        return game.pinned_chunks.contains(id) or if (game.last_camera_chunk_coords) |camera| getChunkDistance(game.layout(), id, camera) <= BLOCK_LOAD_RADIUS else true;
    }

    fn refreshPinnedChunks(game: *Game) void {
        game.pinned_chunks.clearRetainingCapacity();
        for (game.world.?.pending_operations.items) |pending| {
            const coords, const local = world_module.splitBlockCoords(pending.operation.block);
            game.pinned_chunks.put(game.allocator, game.layout().encodeChunkCoords(coords), {}) catch @panic("OOM");
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else consts.CHUNK_SIZE - 1)) continue;
                const neighbor = world_module.adjacentChunk(game.layout(), coords, side) orelse continue;
                game.pinned_chunks.put(game.allocator, game.layout().encodeChunkCoords(neighbor), {}) catch @panic("OOM");
            }
        }
    }

    pub fn updateChunksAroundCamera(game: *Game, _: bool) void {
        const camera = game.layout().getChunkCoords(game.engine.active_scene.?.camera.position);
        game.last_camera_chunk_coords = camera;
        game.refreshPinnedChunks();

        // Retain pending commands and their affected face neighbors even after movement.
        var pins = game.pinned_chunks.keyIterator();
        while (pins.next()) |id| game.requestChunkMode(game.layout().decodeChunkId(id.*), .blocks);
        // Closest shells first: all block requests precede new distant mesh requests.
        var radius: i32 = 0;
        while (radius <= game.render_radius) : (radius += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                var dy = -radius;
                while (dy <= radius) : (dy += 1) {
                    var dx = -radius;
                    while (dx <= radius) : (dx += 1) {
                        if (@max(@abs(dx), @abs(dy), @abs(dz)) != radius) continue;
                        const coords = game.layout().normalizeChunkCoords(camera +| @as(ChunkCoords, .{ dx, dy, dz })) orelse continue;
                        game.requestChunkMode(coords, if (game.wantsBlocks(coords)) .blocks else .mesh);
                    }
                }
            }
        }
        var evicted: std.ArrayList(u32) = .empty;
        defer evicted.deinit(game.allocator);
        var subscriptions = game.chunk_subscriptions.keyIterator();
        while (subscriptions.next()) |id| {
            if (getChunkDistance(game.layout(), id.*, camera) > game.render_radius and !game.pinned_chunks.contains(id.*))
                evicted.append(game.allocator, id.*) catch @panic("OOM");
        }
        for (evicted.items) |id| {
            const token = game.chunk_subscriptions.fetchRemove(id).?.value;
            game.world_client.?.evictChunk(id, token);
            _ = game.chunk_modes.remove(id);
            game.removeChunkByIdIfNeeded(id);
            const coords = game.layout().decodeChunkId(id);
            if (game.world.?.hasChunk(coords)) game.world.?.removeChunk(coords);
            game.markChunkAndNeighborsDirty(coords);
        }
    }

    fn loadChunkIfNeeded(game: *Game, chunk_x: i32, chunk_y: i32, chunk_z: i32) void {
        const world = &game.world.?;

        const chunk_coords = game.layout().normalizeChunkCoords(.{ chunk_x, chunk_y, chunk_z }) orelse return;
        const chunk_id = game.layout().encodeChunkCoords(chunk_coords);

        if (game.loaded_chunk_ids.contains(chunk_id)) {
            return;
        }

        if (!world.hasChunk(chunk_coords)) return;

        game.loaded_chunk_ids.put(game.allocator, chunk_id, {}) catch @panic("OOM");
        game.markChunkDirtyIfLoaded(chunk_coords);
    }

    fn removeChunkIfNeeded(game: *Game, chunk_coords: ChunkCoords) void {
        game.removeChunkByIdIfNeeded(game.layout().encodeChunkCoords(chunk_coords));
    }

    fn removeChunkByIdIfNeeded(game: *Game, chunk_id: u32) void {
        _ = game.dirty_chunk_ids.remove(chunk_id);
        _ = game.mesh_versions.remove(chunk_id);
        _ = game.boundary_snapshots.remove(chunk_id);
        if (game.loaded_chunk_ids.contains(chunk_id)) {
            _ = game.loaded_chunk_ids.remove(chunk_id);
            game.engine.active_scene.?.voxel_grid.removeChunk(game.layout().decodeChunkId(chunk_id));
        }
    }

    fn editBlockUnderCamera(game: *Game, action: BlockAction) void {
        const world = if (game.world) |*world| world else return;

        const camera_position = game.engine.active_scene.?.camera.position;
        const top = getColumnTopUnderPosition(game.layout(), camera_position) orelse return;

        const camera_z = camera_position[2] + @as(f64, @floatFromInt(game.layout().origin_chunk[2] * consts.CHUNK_SIZE));
        if (camera_z - @as(f64, @floatFromInt(top[2] + 1)) > TOOL_REACH) return;
        const minimum_z: u32 = @intFromFloat(@max(0, @floor(camera_z - TOOL_REACH)));
        const edit_result = switch (action) {
            .remove => world.removeTopBlockInColumn(top, minimum_z),
            .add_dirt => world.dropBlockInColumn(top, .dirt, minimum_z),
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

        game.markChunksAroundBlockDirty(edited_block);
    }

    /// Invalidates the edited chunk and face neighbors touched by a boundary edit.
    fn markChunksAroundBlockDirty(game: *Game, block: [3]u32) void {
        const chunk_coords, const local = world_module.splitBlockCoords(block);

        game.markChunkDirtyIfLoaded(chunk_coords);

        for (std.enums.values(Side)) |side| {
            const i = @intFromEnum(side);
            if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else consts.CHUNK_SIZE - 1)) continue;
            const neighbor = world_module.adjacentChunk(game.layout(), chunk_coords, side) orelse continue;
            game.markChunkDirtyIfLoaded(neighbor);
        }
    }

    /// Snapshots don't identify the edited block, so invalidate all face neighbors.
    fn markChunkAndNeighborsDirty(game: *Game, chunk_coords: ChunkCoords) void {
        game.markChunkDirtyIfLoaded(chunk_coords);
        for (std.enums.values(Side)) |side| {
            if (world_module.adjacentChunk(game.layout(), chunk_coords, side)) |coords| game.markChunkDirtyIfLoaded(coords);
        }
    }

    fn markChunkDirtyIfLoaded(game: *Game, chunk_coords: ChunkCoords) void {
        const chunk_id = game.layout().encodeChunkCoords(chunk_coords);
        if (game.loaded_chunk_ids.contains(chunk_id)) {
            game.dirty_chunk_ids.put(game.allocator, chunk_id, {}) catch @panic("OOM");
        }
    }

    /// Run once after edits, responses, and camera loading, before the frame's GPU upload.
    fn rebuildDirtyChunks(game: *Game) void {
        const voxel_grid = game.engine.active_scene.?.voxel_grid;
        const world = &game.world.?;
        defer game.dirty_chunk_ids.clearRetainingCapacity();

        var iterator = game.dirty_chunk_ids.keyIterator();
        while (iterator.next()) |chunk_id| {
            const coords = game.layout().decodeChunkId(chunk_id.*);
            const chunk = world.getChunk(coords) orelse continue;
            // Retained blocks may still receive neighbor changes during a handoff.
            _ = game.mesh_versions.remove(chunk_id.*);
            voxel_grid.removeChunk(coords);
            if (chunk.content == .blocks and !chunk.flags.is_unreachable) {
                voxel_grid.appendChunk(.{
                    .chunk_coords = coords,
                    .chunk_side_data = world_engine.extractChunkSideData(game.allocator, chunk.content, game.meshNeighbors(coords)),
                });
            }
        }
    }
    fn meshNeighbors(game: *const Game, coords: ChunkCoords) world_engine.BoundaryMasks {
        const cached = game.boundary_snapshots.get(game.layout().encodeChunkCoords(coords));
        // A missing dependency is temporarily air. Service snapshots normally supply
        // every plane with the blocks, including neighbors beyond the local core.
        var neighbors: world_engine.BoundaryMasks = if (cached) |snapshot| snapshot.masks else @splat(.{});
        for (std.enums.values(Side)) |side| {
            if (game.localMeshNeighbor(coords, side)) |neighbor| {
                neighbors[@intFromEnum(side)] = neighbor.boundaries[@intFromEnum(side.getOpposite())];
            }
        }
        return neighbors;
    }

    fn localMeshNeighbor(game: *const Game, coords: ChunkCoords, side: Side) ?*const WorldChunk {
        const adjacent = world_module.adjacentChunk(game.layout(), coords, side) orelse return null;
        const adjacent_id = game.layout().encodeChunkCoords(adjacent);
        // A demoted neighbor may retain blocks for its display, but those blocks
        // no longer receive updates. Its authoritative fallback plane is newer.
        if (game.chunk_modes.get(adjacent_id) == .mesh) return null;
        return game.world.?.chunks.getPtr(adjacent_id);
    }
};

/// Consumes the response, including stale and evicted snapshots. Acknowledgements are
/// independent of subscription lifetime so pending edits can always be retired.
fn applyChunkResponse(world: *World, subscriptions: *const std.AutoHashMapUnmanaged(u32, u64), response: ChunkResponse) bool {
    if (response.operation) |result| world.acknowledgeOperation(result.request_id);
    const token = subscriptions.get(world.layout.encodeChunkCoords(response.coords));
    if (token == null or token != response.subscription_id) {
        response.deinit(world.allocator);
        return false;
    }
    if (response.data != .blocks) return false;
    world.insertChunk(response.coords, response.data.blocks.chunk) catch {
        response.deinit(world.allocator);
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
fn getColumnTopUnderPosition(layout: *const WorldLayout, position: Position) ?[3]u32 {
    const origin: @Vector(3, i64) = layout.origin_chunk;
    const block = @as(@Vector(3, i64), @intFromFloat(@floor(position))) +
        origin * @as(@Vector(3, i64), @splat(consts.CHUNK_SIZE));

    const world_size = layout.size_in_blocks;

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
    game.world_data = try WorldDataService.create(game.engine.io, game.allocator, game.engine.active_scene.?.layout, .{ .terrain = .{ .seed = 12345 } });
    game.world = try World.init(game.allocator, game.engine.active_scene.?.layout);
    game.world_client = try game.world_data.?.createClient();
    game.simulation = try SimulationWorker.create(game.world_data.?);
}

/// Chebyshev distance between the chunk and the camera chunk, in chunks. The x axis wraps.
fn getChunkDistance(layout: *const WorldLayout, chunk_id: u32, camera_chunk_coords: ChunkCoords) u64 {
    const delta = layout.getChunkDelta(layout.decodeChunkId(chunk_id), camera_chunk_coords);
    return @reduce(.Max, @abs(delta));
}

/// Calls `context.onRange(z_start, z_end)` for every range [z_start, z_end) of consecutive z
/// in [z_min, z_max] for which `context.isMissing(z)` is true. Does nothing if z_min > z_max.
fn forEachMissingChunkRange(z_min: i32, z_max: i32, context: anytype) void {
    var range_start: ?i32 = null;
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

/// Returns neighbors indexed by Side; null items are outside the stored world.
/// Returns null if a neighbor has not been received from the world-data thread yet.
fn getSurroundingChunks(world: *const World, coords: ChunkCoords) ?[6]?WorldChunk {
    var result: [6]?WorldChunk = @splat(null);
    for (std.enums.values(Side)) |side| {
        const neighbor = world_module.adjacentChunk(world.layout, coords, side) orelse continue;
        result[@intFromEnum(side)] = world.getChunk(neighbor) orelse return null;
    }
    return result;
}

const ChunkBox = struct {
    start: ChunkCoords,
    end: ChunkCoords, // end is inclusive

    pub fn isContainingChunk(self: *const ChunkBox, chunk: ChunkCoords) bool {
        return @reduce(.And, chunk >= self.start) and
            @reduce(.And, chunk <= self.end);
    }
};

fn getBoxAroundChunk(chunk_coords: ChunkCoords, radius: i32) ChunkBox {
    std.debug.assert(radius >= 0);
    const delta: ChunkCoords = @splat(radius);
    // Query only representable coordinates when the camera reaches a signed limit.
    return .{
        .start = chunk_coords -| delta,
        .end = chunk_coords +| delta,
    };
}

fn fitBoxIntoWorld(layout: *const WorldLayout, box: ChunkBox) ChunkBox {
    // X wraps, so only y/z are clipped to the stored world.
    return .{
        .start = @max(box.start, ChunkCoords{ std.math.minInt(i32), 0, 0 }),
        .end = @min(box.end, ChunkCoords{ std.math.maxInt(i32), layout.size_in_chunks[1] - 1, layout.size_in_chunks[2] - 1 }),
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

    const scene = try engine.createScene(consts.WORLD_SETTINGS);
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

        group.setPosition(.{ 0, 0, 0 });

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
    //     group.setPosition(.{ 0, 0, math.sin(engine.time) * 10 });
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

test "chunk loads, edits, and snapshots share one rebuild using the final contents" {
    const allocator = std.testing.allocator;
    // Exercise mesh generation and removal without creating a GPU device.
    var grid: @import("engine").VoxelGrid = .{
        .allocator = allocator,
        .gpu_chunk_info_buffer = undefined,
        .gpu_block_buffer = undefined,
    };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    var scene: Scene = undefined;
    scene.voxel_grid = &grid;
    var engine: Engine = undefined;
    engine.active_scene = &scene;
    var game: Game = .{ .allocator = allocator, .engine = &engine, .world = try World.init(allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(allocator);
    defer game.dirty_chunk_ids.deinit(allocator);
    defer game.chunk_subscriptions.deinit(allocator);

    const coords = ChunkCoords{ 1, 1, 1 };
    const chunk_id = test_layout.encodeChunkCoords(coords);
    const block = [3]u32{ consts.CHUNK_SIZE + 2, consts.CHUNK_SIZE + 3, consts.CHUNK_SIZE + 4 };
    var initial = WorldChunk.initEmpty();
    _ = initial.apply(allocator, .{ 2, 3, 4 }, .{ .put = .dirt });
    try game.world.?.insertChunk(coords, initial);
    game.loadChunkIfNeeded(1, 1, 1);
    game.loadChunkIfNeeded(1, 1, 1);

    game.world.?.setBlock(block, .none);
    game.markChunksAroundBlockDirty(block);
    game.world.?.setBlock(block, .grass);
    game.markChunksAroundBlockDirty(block);

    try game.chunk_subscriptions.put(allocator, chunk_id, 1);
    var snapshot = WorldChunk.initEmpty();
    snapshot.chunk_revision = 1;
    try std.testing.expect(applyChunkResponse(&game.world.?, &game.chunk_subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .data = .{ .blocks = .{ .chunk = snapshot } },
    }));
    game.markChunkAndNeighborsDirty(coords);

    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(1, game.dirty_chunk_ids.count());
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, game.dirty_chunk_ids.count());
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    const upload = grid.chunks_to_upload.items[0];
    try std.testing.expectEqual(coords, upload.chunk_coords);
    for (upload.chunk_side_data.blocks_grouped_by_side) |side| {
        try std.testing.expectEqual(1, side.items.len);
        try std.testing.expectEqual(voxel_chunk_module.BlockType.grass, side.items[0].block_type);
        try std.testing.expectEqual([3]u8{ 2, 3, 4 }, side.items[0].coords);
    }
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);

    // After the upload, a later frame can dirty the same chunk again. Removing its last
    // block must remove its previous mesh even though there is no replacement to upload.
    grid.clearChunks();
    try grid.chunks.append(allocator, voxel_chunk_module.VoxelChunk.init(coords));
    game.world.?.setBlock(block, .none);
    game.markChunksAroundBlockDirty(block);
    try std.testing.expectEqual(1, grid.chunks.items.len);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, grid.chunks.items.len);
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(game.loaded_chunk_ids.contains(chunk_id));

    // An empty loaded chunk can become visible again in a subsequent frame.
    game.world.?.setBlock(block, .stone);
    game.markChunksAroundBlockDirty(block);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    grid.clearChunks();

    // Unloading cancels pending work, and later invalidations don't reload the chunk.
    game.markChunkAndNeighborsDirty(coords);
    game.removeChunkByIdIfNeeded(chunk_id);
    game.markChunksAroundBlockDirty(block);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, game.dirty_chunk_ids.count());
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(!game.loaded_chunk_ids.contains(chunk_id));
}

test "boundary edits dirty only loaded face neighbors with world wrapping and limits" {
    var game: Game = .{ .allocator = std.testing.allocator, .engine = undefined, .world = try World.init(std.testing.allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(game.allocator);
    defer game.dirty_chunk_ids.deinit(game.allocator);
    const neighbors = [_]ChunkCoords{
        .{ 0, 0, 0 },
        .{ test_layout.size_in_chunks[0] - 1, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
        .{ 1, 1, 1 }, // A diagonal neighbor never needs rebuilding.
    };
    for (neighbors) |coords| {
        try game.loaded_chunk_ids.put(game.allocator, test_layout.encodeChunkCoords(coords), {});
    }

    game.markChunksAroundBlockDirty(.{ 0, 0, 0 });
    game.markChunksAroundBlockDirty(.{ 0, 0, 0 });
    try std.testing.expectEqual(2, game.dirty_chunk_ids.count());
    try std.testing.expect(game.dirty_chunk_ids.contains(test_layout.encodeChunkId(0, 0, 0)));
    try std.testing.expect(game.dirty_chunk_ids.contains(test_layout.encodeChunkId(test_layout.size_in_chunks[0] - 1, 0, 0)));

    game.dirty_chunk_ids.clearRetainingCapacity();
    const last = consts.CHUNK_SIZE - 1;
    game.markChunksAroundBlockDirty(.{ last, last, last });
    try std.testing.expectEqual(4, game.dirty_chunk_ids.count());
    for ([_]usize{ 0, 2, 3, 4 }) |i| {
        try std.testing.expect(game.dirty_chunk_ids.contains(test_layout.encodeChunkCoords(neighbors[i])));
    }

    // Full snapshots invalidate all loaded face neighbors, sharing the same dirty set.
    game.markChunkAndNeighborsDirty(.{ 0, 0, 0 });
    try std.testing.expectEqual(5, game.dirty_chunk_ids.count());
    try std.testing.expect(!game.dirty_chunk_ids.contains(test_layout.encodeChunkId(1, 1, 1)));
    game.markChunksAroundBlockDirty(.{ 2 * consts.CHUNK_SIZE + 1, 1, 1 });
    try std.testing.expectEqual(5, game.dirty_chunk_ids.count());
}

test "chunk distance is the largest axis distance and wraps around x" {
    const camera = ChunkCoords{ 0, 10, 2 };
    const world_width: i32 = test_layout.size_in_chunks[0];

    try std.testing.expectEqual(0, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), camera));
    try std.testing.expectEqual(3, getChunkDistance(&test_layout, test_layout.encodeChunkId(3, 10, 2), camera));
    try std.testing.expectEqual(1, getChunkDistance(&test_layout, test_layout.encodeChunkId(test_layout.size_in_chunks[0] - 1, 10, 2), camera));
    try std.testing.expectEqual(1, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), .{ world_width - 1, 10, 2 }));
    try std.testing.expectEqual(1, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), .{ -1, 10, 2 }));
    try std.testing.expectEqual(world_width / 2, getChunkDistance(&test_layout, test_layout.encodeChunkId(test_layout.size_in_chunks[0] / 2, 10, 2), camera));

    try std.testing.expectEqual(4, getChunkDistance(&test_layout, test_layout.encodeChunkId(1, 6, 2), camera));
    try std.testing.expectEqual(10, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 0, 2), camera));
    try std.testing.expectEqual(test_layout.size_in_chunks[1] - 1 - 10, getChunkDistance(&test_layout, test_layout.encodeChunkId(0, test_layout.size_in_chunks[1] - 1, 2), camera));
    try std.testing.expectEqual(2, getChunkDistance(&test_layout, test_layout.encodeChunkId(1, 11, 0), camera));
    try std.testing.expectEqual(test_layout.size_in_chunks[2] - 1 - 2, getChunkDistance(&test_layout, test_layout.encodeChunkId(1, 11, test_layout.size_in_chunks[2] - 1), camera));
    try std.testing.expectEqual(@as(u64, 2147483658), getChunkDistance(&test_layout, test_layout.encodeChunkId(0, 10, 2), .{ 0, std.math.minInt(i32), 2 }));
}

test "chunk coords wrap around x and are out of the world beyond y and z" {
    const width: i32 = test_layout.size_in_chunks[0];
    const depth: i32 = test_layout.size_in_chunks[1];
    const height: i32 = test_layout.size_in_chunks[2];

    try std.testing.expectEqual(ChunkCoords{ 1, 2, 3 }, test_layout.normalizeChunkCoords(.{ 1, 2, 3 }).?);
    try std.testing.expectEqual(ChunkCoords{ test_layout.size_in_chunks[0] - 1, 0, 0 }, test_layout.normalizeChunkCoords(.{ -1, 0, 0 }).?);
    try std.testing.expectEqual(ChunkCoords{ 0, test_layout.size_in_chunks[1] - 1, test_layout.size_in_chunks[2] - 1 }, test_layout.normalizeChunkCoords(.{ width, depth - 1, height - 1 }).?);
    try std.testing.expectEqual(ChunkCoords{ width - 1, 2, 3 }, test_layout.normalizeChunkCoords(.{ -3 * width - 1, 2, 3 }).?);
    try std.testing.expectEqual(ChunkCoords{ 1, 2, 3 }, test_layout.normalizeChunkCoords(.{ 4 * width + 1, 2, 3 }).?);
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, -1, 0 }));
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, depth, 0 }));
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, 0, -1 }));
    try std.testing.expectEqual(null, test_layout.normalizeChunkCoords(.{ 0, 0, height }));
}

test "box around a chunk is clamped to the world along y and z only" {
    const box = fitBoxIntoWorld(&test_layout, getBoxAroundChunk(.{ 0, 1, test_layout.size_in_chunks[2] - 1 }, 2));
    try std.testing.expectEqual(ChunkCoords{ -2, 0, test_layout.size_in_chunks[2] - 3 }, box.start);
    try std.testing.expectEqual(ChunkCoords{ 2, 3, test_layout.size_in_chunks[2] - 1 }, box.end);
    try std.testing.expect(box.isContainingChunk(.{ -2, 0, test_layout.size_in_chunks[2] - 1 }));
    try std.testing.expect(!box.isContainingChunk(.{ 3, 0, test_layout.size_in_chunks[2] - 1 }));
}

test "camera at signed chunk limits requests no terrain and does not overflow" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    // No request can be issued: the service pointer is deliberately absent.
    fixture.camera.position = .{ 0, (@as(f64, std.math.minInt(i32)) - test_layout.origin_chunk[1]) * consts.CHUNK_SIZE, 0 };
    fixture.game.updateChunksAroundCamera(true);
    try std.testing.expectEqual(0, fixture.game.chunk_subscriptions.count());
    const box = getBoxAroundChunk(.{ 0, std.math.minInt(i32), std.math.maxInt(i32) }, 3);
    try std.testing.expectEqual(std.math.minInt(i32), box.start[1]);
    try std.testing.expectEqual(std.math.maxInt(i32), box.end[2]);
}

test "voxel upload queue retains negative spatial chunks and removes only matching coordinates" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords: ChunkCoords = .{ -1, -2, -3 };
    fixture.grid.appendChunk(.{ .chunk_coords = coords, .chunk_side_data = .{} });
    fixture.grid.appendChunk(.{ .chunk_coords = .{ -1, -2, -4 }, .chunk_side_data = .{} });
    try std.testing.expectEqual(coords, fixture.grid.chunks_to_upload.items[0].chunk_coords);
    fixture.grid.removeChunk(coords);
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(ChunkCoords{ -1, -2, -4 }, fixture.grid.chunks_to_upload.items[0].chunk_coords);
}

test "column top under a position is clamped to the top of the world" {
    const origin = [3]u32{
        test_layout.origin_chunk[0] * consts.CHUNK_SIZE,
        test_layout.origin_chunk[1] * consts.CHUNK_SIZE,
        test_layout.origin_chunk[2] * consts.CHUNK_SIZE,
    };
    const world_size = test_layout.size_in_blocks;

    try std.testing.expectEqual(origin, getColumnTopUnderPosition(&test_layout, .{ 0.5, 0.5, 0.5 }).?);
    try std.testing.expectEqual([3]u32{ origin[0] - 1, origin[1] - 1, origin[2] - 1 }, getColumnTopUnderPosition(&test_layout, .{ -0.5, -0.5, -0.5 }).?);
    try std.testing.expectEqual([3]u32{ origin[0], origin[1], world_size[2] - 1 }, getColumnTopUnderPosition(&test_layout, .{ 0, 0, 1.0e6 }).?);
    try std.testing.expectEqual([3]u32{ world_size[0] - 1, origin[1], origin[2] }, getColumnTopUnderPosition(&test_layout, .{ -@as(f32, @floatFromInt(origin[0])) - 1, 0, 0 }).?);
    try std.testing.expectEqual(null, getColumnTopUnderPosition(&test_layout, .{ 0, 0, -@as(f32, @floatFromInt(origin[2])) - 1 }));
    try std.testing.expectEqual(null, getColumnTopUnderPosition(&test_layout, .{ 0, @floatFromInt(world_size[1]), 0 }));
}

const TestColumn = struct {
    is_missing: []const bool,
    ranges: std.ArrayList([2]i32) = .empty,

    fn isMissing(self: *const TestColumn, z: i32) bool {
        return self.is_missing[@intCast(z)];
    }

    fn onRange(self: *TestColumn, z_start: i32, z_end: i32) void {
        self.ranges.append(std.testing.allocator, .{ z_start, z_end }) catch @panic("OOM");
    }
};

fn expectMissingChunkRanges(expected: []const [2]i32, z_min: i32, z_max: i32, is_missing: []const bool) !void {
    var column = TestColumn{ .is_missing = is_missing };
    defer column.ranges.deinit(std.testing.allocator);

    forEachMissingChunkRange(z_min, z_max, &column);
    try std.testing.expectEqualSlices([2]i32, expected, column.ranges.items);
}

test "missing chunks of a column are split into ranges of consecutive chunks" {
    const height = test_layout.size_in_chunks[2];
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
    const all_missing: [test_layout.size_in_chunks[2]]bool = @splat(true);

    try expectMissingChunkRanges(&.{}, 0, -3, &all_missing);
    try expectMissingChunkRanges(&.{}, test_layout.size_in_chunks[2] + 2, test_layout.size_in_chunks[2] - 1, &all_missing);
}

test "evicted edit replies retire pending work without restoring chunks" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    var subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer subscriptions.deinit(std.testing.allocator);
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 0, 0, 0 }, .dirt);
    world.pending_operations.items[0].request_id = 7;
    world.removeChunk(coords);
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .operation = .{ .request_id = 7, .status = .already_exists },
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
    try std.testing.expect(!world.hasChunk(coords));
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    // A response without a subscription must never be accepted just because both are null.
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = null,
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
}

test "new subscription rejects queued snapshots from an evicted generation" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    var subscriptions: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer subscriptions.deinit(std.testing.allocator);
    const coords = ChunkCoords{ 0, 0, 0 };
    try subscriptions.put(std.testing.allocator, test_layout.encodeChunkCoords(coords), 2);
    try std.testing.expect(!applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
    try std.testing.expect(applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 2,
        .data = .{ .blocks = .{ .chunk = WorldChunk.initEmpty() } },
    }));
    var update = WorldChunk.initEmpty();
    _ = update.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .dirt });
    update.chunk_revision = 1;
    try std.testing.expect(applyChunkResponse(&world, &subscriptions, .{
        .coords = coords,
        .subscription_id = 2,
        .data = .{ .blocks = .{ .chunk = update } },
    }));
    try std.testing.expect(try world.isBlockSolid(.{ 1, 2, 3 }));
    try std.testing.expectEqual(2, subscriptions.get(test_layout.encodeChunkCoords(coords)));
}

test "unreachable chunks keep CPU blocks and queue a mesh immediately after a local reveal" {
    const allocator = std.testing.allocator;
    var grid: @import("engine").VoxelGrid = .{
        .allocator = allocator,
        .gpu_chunk_info_buffer = undefined,
        .gpu_block_buffer = undefined,
    };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    var scene: Scene = undefined;
    scene.voxel_grid = &grid;
    var engine: Engine = undefined;
    engine.active_scene = &scene;
    var game: Game = .{ .allocator = allocator, .engine = &engine, .world = try World.init(allocator, &test_layout) };
    defer game.world.?.deinit();
    defer game.loaded_chunk_ids.deinit(allocator);
    defer game.dirty_chunk_ids.deinit(allocator);
    defer game.chunk_subscriptions.deinit(allocator);
    const coords = ChunkCoords{ 1, 1, 2 };
    var prepared = try world_generator.WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const column = world_generator.ColumnGenerator.init(&prepared, .{ 1, 1 });
    try game.world.?.insertChunk(coords, column.generateChunk(allocator, 2));
    try game.world.?.insertChunk(.{ 1, 1, 3 }, column.generateChunk(allocator, 3));
    game.loadChunkIfNeeded(1, 1, 2);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try std.testing.expect(game.loaded_chunk_ids.contains(test_layout.encodeChunkCoords(coords)));
    try std.testing.expect(game.world.?.getChunk(coords).?.flags.is_unreachable);
    try std.testing.expect(try game.world.?.isBlockSolid(.{ consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8, 2 * consts.CHUNK_SIZE + 31 }));

    // The service has not been contacted. Opening the bottom wall of the surface chunk
    // reveals the chunk below and queues its mesh in this same frame.
    const block = [3]u32{ consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8, 3 * consts.CHUNK_SIZE };
    game.world.?.setBlock(block, .none);
    game.markChunksAroundBlockDirty(block);
    try std.testing.expectEqual(1, game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(0, game.world.?.getChunk(coords).?.chunk_revision);
    try std.testing.expect(!game.world.?.getChunk(coords).?.flags.is_unreachable);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(coords, grid.chunks_to_upload.items[0].chunk_coords);
    for (grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side, 0..) |side, i| {
        // The neighboring chunk above now exposes only the single removed wall block.
        try std.testing.expectEqual(if (i == @intFromEnum(Side.top)) @as(usize, 1) else consts.CHUNK_SIZE * consts.CHUNK_SIZE, side.items.len);
    }
    grid.clearChunks();

    // An older in-flight load cannot hide the chunk while the wall edit is outstanding.
    try game.chunk_subscriptions.put(allocator, test_layout.encodeChunkCoords(coords), 1);
    try std.testing.expect(applyChunkResponse(&game.world.?, &game.chunk_subscriptions, .{
        .coords = coords,
        .subscription_id = 1,
        .data = .{ .blocks = .{ .chunk = column.generateChunk(allocator, 2) } },
    }));
    game.markChunkAndNeighborsDirty(coords);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(coords, grid.chunks_to_upload.items[0].chunk_coords);
    grid.clearChunks();

    // A service-only metadata change also invalidates a hidden chunk's GPU state.
    const remote_coords = ChunkCoords{ 5, 5, 2 };
    const remote_column = world_generator.ColumnGenerator.init(&prepared, .{ 5, 5 });
    try game.world.?.insertChunk(remote_coords, remote_column.generateChunk(allocator, 2));
    game.loadChunkIfNeeded(5, 5, 2);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, grid.chunks_to_upload.items.len);
    try game.chunk_subscriptions.put(allocator, test_layout.encodeChunkCoords(remote_coords), 2);
    var reveal = remote_column.generateChunk(allocator, 2);
    reveal.flags.is_unreachable = false;
    reveal.chunk_revision = 1;
    try std.testing.expect(applyChunkResponse(&game.world.?, &game.chunk_subscriptions, .{
        .coords = remote_coords,
        .subscription_id = 2,
        .data = .{ .blocks = .{ .chunk = reveal } },
    }));
    game.markChunkAndNeighborsDirty(remote_coords);
    game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(remote_coords, grid.chunks_to_upload.items[0].chunk_coords);
}

/// Exercises the actual subscription and upload paths without a graphics device.
const StreamingTest = struct {
    camera: std.meta.Child(@TypeOf(@as(Scene, undefined).camera)) = undefined,
    grid: @import("engine").VoxelGrid = undefined,
    scene: Scene = undefined,
    engine: Engine = undefined,
    game: Game = undefined,

    fn init(self: *StreamingTest) void {
        self.initWithLayout(&test_layout);
    }

    fn initWithLayout(self: *StreamingTest, layout: *const WorldLayout) void {
        self.scene.layout = layout;
        self.camera.layout = self.scene.layout;
        self.camera.position = .{ 0, 0, 0 };
        self.grid = .{ .allocator = std.testing.allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined };
        self.scene.voxel_grid = &self.grid;
        self.scene.camera = &self.camera;
        self.engine.active_scene = &self.scene;
        self.game = .{ .allocator = std.testing.allocator, .engine = &self.engine, .world = World.init(std.testing.allocator, self.scene.layout) catch unreachable };
    }

    fn deinit(self: *StreamingTest) void {
        const allocator = self.game.allocator;
        self.game.world.?.deinit();
        self.game.chunk_subscriptions.deinit(allocator);
        self.game.chunk_modes.deinit(allocator);
        self.game.mesh_versions.deinit(allocator);
        self.game.boundary_snapshots.deinit(allocator);
        self.game.pinned_chunks.deinit(allocator);
        self.game.loaded_chunk_ids.deinit(allocator);
        self.game.dirty_chunk_ids.deinit(allocator);
        for (self.game.chunk_packages.items) |*package| package.deinit(allocator);
        self.game.chunk_packages.deinit(allocator);
        self.grid.clearChunks();
        self.grid.chunks.deinit(allocator);
        self.grid.chunks_to_upload.deinit(allocator);
    }

    fn subscribe(self: *StreamingTest, coords: ChunkCoords, token: u64, mode: world_data_service.Representation) !void {
        try self.game.chunk_subscriptions.put(self.game.allocator, self.game.layout().encodeChunkCoords(coords), token);
        try self.game.chunk_modes.put(self.game.allocator, self.game.layout().encodeChunkCoords(coords), mode);
    }

    fn apply(self: *StreamingTest, responses: []const ChunkResponse) !void {
        var package: world_data_service.ResponsePackage = .{};
        try package.responses.appendSlice(self.game.allocator, responses);
        defer package.responses.deinit(self.game.allocator);
        self.game.applyPackage(&package);
    }

    fn settled(self: *const StreamingTest) bool {
        if (self.game.world.?.pending_operations.items.len != 0) return false;
        var iterator = self.game.chunk_modes.iterator();
        while (iterator.next()) |entry| {
            const coords = self.game.layout().decodeChunkId(entry.key_ptr.*);
            if (!self.game.loaded_chunk_ids.contains(entry.key_ptr.*)) return false;
            if ((entry.value_ptr.* == .blocks) != self.game.world.?.hasChunk(coords)) return false;
        }
        return true;
    }

    fn drainUntilSettled(self: *StreamingTest) !void {
        while (!self.settled()) {
            var packages: std.ArrayList(world_data_service.ResponsePackage) = .empty;
            try std.testing.expect(try self.game.world_client.?.waitPackages(&packages));
            for (packages.items) |*package| {
                self.game.applyPackage(package);
                package.responses.deinit(self.game.allocator);
            }
            packages.deinit(self.game.allocator);
            self.game.updateChunksAroundCamera(true);
            self.game.rebuildDirtyChunks();
        }
    }
};

fn singleTestBlock(local: [3]u5, revision: u32) WorldChunk {
    var chunk = WorldChunk.initEmpty();
    _ = chunk.apply(std.testing.allocator, local, .{ .put = .stone });
    chunk.chunk_revision = revision;
    return chunk;
}

test "promotion reuses matching authoritative mesh but rejects a neighbor-only revision change" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    const chunk = singleTestBlock(.{ 31, 8, 8 }, 12);
    defer chunk.content.deinit(std.testing.allocator);
    try fixture.subscribe(coords, 1, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 12, .mesh_revision = 20, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, @splat(.{})) } }});
    try std.testing.expect(!fixture.game.world.?.hasChunk(coords));
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr;
    try fixture.subscribe(coords, 2, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 12, .mesh_revision = 20, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(fixture.game.mesh_versions.contains(id));
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr);

    try fixture.game.world.?.insertChunk(.{ 2, 1, 1 }, singleTestBlock(.{ 0, 8, 8 }, 1));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 12, .mesh_revision = 21, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expect(!fixture.game.mesh_versions.contains(id));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "pending neighboring edit prevents canonical mesh reuse and mode tokens reject late payloads" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    const chunk = singleTestBlock(.{ 31, 8, 8 }, 1);
    defer chunk.content.deinit(std.testing.allocator);
    try fixture.game.world.?.insertChunk(neighbor, singleTestBlock(.{ 0, 8, 8 }, 1));
    try fixture.subscribe(coords, 1, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .mesh_revision = 4, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, fixture.game.meshNeighbors(coords)) } }});
    fixture.game.world.?.setBlock(.{ 2 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 }, .none);
    try fixture.subscribe(coords, 2, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 4, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator) } } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    // Even a numerically newer mesh cannot cross an obsolete subscription generation.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 100, .mesh_revision = 100, .data = .{ .mesh = .{} } }});
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expect(!fixture.game.mesh_versions.contains(test_layout.encodeChunkCoords(coords)));
}

test "outward faces follow remote masks while local optimistic neighbors take precedence" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 2, 1, 1 };
    fixture.game.last_camera_chunk_coords = .{ 1, 1, 1 };
    var masks: world_engine.BoundaryMasks = @splat(.{});
    masks[@intFromEnum(Side.right)] = .{ .rows = @splat(std.math.maxInt(u32)) };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 31, 8, 8 }, 0), .neighbors = masks } } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    // A neighbor-only update exposes this outward face without loading distant blocks.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try std.testing.expect(!fixture.game.world.?.hasChunk(.{ 3, 1, 1 }));
    try fixture.game.world.?.insertChunk(.{ 3, 1, 1 }, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.markChunkAndNeighborsDirty(.{ 3, 1, 1 });
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    const edited = [3]u32{ 3 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlock(edited, .none);
    fixture.game.markChunksAroundBlockDirty(edited);
    // The authoritative fallback still contains the block we just removed optimistically.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = masks } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "mixed packages retire all commands and produce one final optimistic mesh" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const block = [3]u32{ consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 8, 8, 8 }, 0));
    fixture.game.loadChunkIfNeeded(1, 1, 1);
    fixture.game.world.?.setBlock(block, .none);
    fixture.game.world.?.setBlock(block, .dirt);
    fixture.game.world.?.pending_operations.items[0].request_id = 10;
    fixture.game.world.?.pending_operations.items[1].request_id = 11;
    var removed = WorldChunk.initEmpty();
    removed.chunk_revision = 1;
    try fixture.apply(&.{
        .{ .coords = coords, .subscription_id = 1, .operation = .{ .request_id = 10, .status = .success }, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = removed } } },
        .{ .coords = coords, .subscription_id = 1, .operation = .{ .request_id = 11, .status = .already_exists }, .chunk_revision = 2, .mesh_revision = 2, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 8, 8, 8 }, 2) } } },
    });
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items.len);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    for (fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side) |side| try std.testing.expectEqual(voxel_chunk_module.BlockType.stone, side.items[0].block_type);
}

test "streaming holds 27 block chunks, pins edits across movement, and completes mesh handoffs" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    fixture.game.updateChunksAroundCamera(false);
    try fixture.drainUntilSettled();
    try std.testing.expectEqual(343, fixture.game.chunk_subscriptions.count());
    try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
    const origin = test_layout.origin_chunk;
    const block = [3]u32{ origin[0] * consts.CHUNK_SIZE, origin[1] * consts.CHUNK_SIZE + 8, origin[2] * consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlock(block, .dirt);
    fixture.game.markChunksAroundBlockDirty(block);
    fixture.game.flushBlockOperations();
    fixture.camera.position[0] = 64;
    fixture.game.updateChunksAroundCamera(false);
    try std.testing.expectEqual(2, fixture.game.pinned_chunks.count());
    try std.testing.expectEqual(world_data_service.Representation.blocks, fixture.game.chunk_modes.get(test_layout.encodeChunkCoords(origin)).?);
    try fixture.drainUntilSettled();
    try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
    try std.testing.expectEqual(343, fixture.game.chunk_subscriptions.count());
    try std.testing.expectEqual(0, fixture.game.pinned_chunks.count());
    try std.testing.expect(!fixture.game.world.?.hasChunk(origin));
    try std.testing.expect(fixture.game.mesh_versions.contains(test_layout.encodeChunkCoords(origin)));
    try std.testing.expect(fixture.grid.hasUploadCapacity());

    // Reverse while mesh and block requests are still in flight; obsolete tokens must drain.
    fixture.camera.position[0] = 96;
    fixture.game.updateChunksAroundCamera(false);
    fixture.camera.position[0] = 0;
    fixture.game.updateChunksAroundCamera(false);
    try fixture.drainUntilSettled();
    try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
    try std.testing.expect(try fixture.game.world.?.isBlockSolid(block));
}

test "column tools stop within 20 blocks of the actual camera and never place at an unsupported limit" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.camera.position = .{ 0.5, 0.5, 20.5 };
    const origin = test_layout.origin_chunk;
    try fixture.game.world.?.insertChunk(origin, WorldChunk.initEmpty());
    // This surface is 19.5 blocks below the camera, so removal is allowed.
    fixture.game.world.?.setBlock(.{ origin[0] * consts.CHUNK_SIZE, origin[1] * consts.CHUNK_SIZE, origin[2] * consts.CHUNK_SIZE }, .stone);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    fixture.game.editBlockUnderCamera(.remove);
    try std.testing.expectEqual(1, fixture.game.world.?.pending_operations.items.len);
    fixture.game.world.?.pending_operations.clearRetainingCapacity();
    // An empty search must stop before looking into the missing chunk below the core.
    fixture.game.editBlockUnderCamera(.add_dirt);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    var below = WorldChunk.initEmpty();
    _ = below.apply(std.testing.allocator, .{ 0, 0, 31 }, .{ .put = .stone });
    try fixture.game.world.?.insertChunk(.{ origin[0], origin[1], origin[2] - 1 }, below);
    fixture.game.editBlockUnderCamera(.remove);
    fixture.game.editBlockUnderCamera(.add_dirt);
    try std.testing.expectEqual(0, fixture.game.world.?.pending_operations.items.len);
    // Moving one block closer makes that same surface reachable for placement.
    fixture.camera.position[2] -= 1;
    fixture.game.editBlockUnderCamera(.add_dirt);
    try std.testing.expectEqual(1, fixture.game.world.?.pending_operations.items.len);
}

test "demotion retains complete local geometry and masks until the service mesh arrives" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 2, 2, 2 };
    fixture.game.last_camera_chunk_coords = .{ 3, 2, 2 };
    try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.loadChunkIfNeeded(2, 2, 2);
    fixture.game.installBoundaries(coords, @splat(.{}), 0);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr;
    fixture.game.last_camera_chunk_coords = .{ 0, 2, 2 };
    try fixture.subscribe(coords, 2, .mesh);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[0].items.ptr);
    try std.testing.expect(fixture.game.boundary_snapshots.contains(test_layout.encodeChunkCoords(coords)));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .data = .{ .mesh = .{} } }});
    try std.testing.expect(!fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(!fixture.game.boundary_snapshots.contains(test_layout.encodeChunkCoords(coords)));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    for (fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side) |side| try std.testing.expectEqual(0, side.items.len);
}

test "unreachable status completes demotion without uploading and cannot hide a later reveal" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 2, 2, 2 };
    const id = test_layout.encodeChunkCoords(coords);
    const chunk = singleTestBlock(.{ 8, 8, 8 }, 0);
    defer chunk.content.deinit(std.testing.allocator);
    try fixture.game.world.?.insertChunk(coords, chunk.clone(std.testing.allocator));
    fixture.game.loadChunkIfNeeded(2, 2, 2);
    fixture.game.rebuildDirtyChunks();
    try fixture.subscribe(coords, 2, .mesh);
    fixture.game.markChunkDirtyIfLoaded(coords);
    // A late reply from a previous subscription must preserve the retained display.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .data = .unreachable_chunk }});
    try std.testing.expect(fixture.game.world.?.hasChunk(coords));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);

    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 0, .mesh_revision = 4, .data = .unreachable_chunk }});
    try std.testing.expect(!fixture.game.world.?.hasChunk(coords));
    try std.testing.expect(fixture.game.loaded_chunk_ids.contains(id));
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expectEqual(2, fixture.game.chunk_subscriptions.get(id).?);
    try std.testing.expectEqual(0, fixture.game.mesh_versions.get(id).?.chunk_revision);
    try std.testing.expectEqual(4, fixture.game.mesh_versions.get(id).?.mesh_revision);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items.len);

    // The same subscription resumes mesh delivery when its enclosure is opened.
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 5, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, @splat(.{})) } }});
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 0, .mesh_revision = 4, .data = .unreachable_chunk }});
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(5, fixture.game.mesh_versions.get(id).?.mesh_revision);
    for (fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side) |side| try std.testing.expectEqual(1, side.items.len);
}

test "GPU preflight reduces subscriptions to 5x5x5 without writing a partial upload" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    // Occupy every allocator span. The undefined graphics device must never be accessed.
    for (0..64) |_| _ = try fixture.grid.gpu_block_buffer_manager.occupyBlock(.{ .size_exponent = 6 });
    var mesh: voxel_chunk_module.ChunkSideData = .{};
    try mesh.blocks_grouped_by_side[0].append(std.testing.allocator, .{ .coords = .{ 8, 8, 8 }, .block_type = .stone });
    fixture.grid.appendChunk(.{ .chunk_coords = .{ 0, 0, 0 }, .chunk_side_data = mesh });
    fixture.game.updateWorld();
    try std.testing.expectEqual(2, fixture.game.render_radius);
    try std.testing.expectEqual(125, fixture.game.chunk_subscriptions.count());
    try std.testing.expect(fixture.game.gpu_capacity_warning);
    try std.testing.expect(fixture.grid.chunks_to_upload.items.len > 0);
}

test "movement retains certified meshes and remote boundary changes invalidate them without movement" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    fixture.game.world_client = try service.createClient();
    const origin = test_layout.origin_chunk;
    const coords = ChunkCoords{ origin[0] + 1, origin[1], origin[2] };
    const id = test_layout.encodeChunkCoords(coords);
    const chunk = singleTestBlock(.{ 31, 8, 8 }, 1);
    defer chunk.content.deinit(std.testing.allocator);
    var neighbors: world_engine.BoundaryMasks = @splat(.{});
    neighbors[@intFromEnum(Side.right)] = .{ .rows = @splat(std.math.maxInt(u32)) };
    try fixture.subscribe(coords, 1, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, neighbors) } }});
    try fixture.subscribe(coords, 2, .blocks);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator), .neighbors = neighbors } } }});
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.last_camera_chunk_coords = origin;
    fixture.camera.position[0] = 32;
    fixture.game.updateChunksAroundCamera(false);
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expect(fixture.game.mesh_versions.contains(id));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 2, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
    try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "newer boundary inputs prevent promotion reuse in either package order and reject stale planes" {
    for ([_]bool{ false, true }) |boundaries_first| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const coords = ChunkCoords{ 1, 1, 1 };
        const id = test_layout.encodeChunkCoords(coords);
        const chunk = singleTestBlock(.{ 31, 8, 8 }, 1);
        defer chunk.content.deinit(std.testing.allocator);
        try fixture.subscribe(coords, 1, .mesh);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .chunk_revision = 1, .mesh_revision = 8, .data = .{ .mesh = world_engine.extractChunkSideData(std.testing.allocator, chunk.content, @splat(.{})) } }});
        try fixture.subscribe(coords, 2, .blocks);
        var masks: world_engine.BoundaryMasks = @splat(.{});
        masks[@intFromEnum(Side.right)].set(.right, .{ 31, 8, 8 }, true);
        const block_response: ChunkResponse = .{ .coords = coords, .subscription_id = 2, .chunk_revision = 1, .mesh_revision = 8, .data = .{ .blocks = .{ .chunk = chunk.clone(std.testing.allocator), .neighbors = @splat(.{}) } } };
        const mask_response: ChunkResponse = .{ .coords = coords, .subscription_id = 2, .mesh_revision = 9, .data = .{ .boundaries = masks } };
        try fixture.apply(if (boundaries_first) &.{ mask_response, block_response } else &.{ block_response, mask_response });
        try std.testing.expectEqual(9, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        // Applying a package never uploads intermediate local geometry.
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
        try fixture.apply(&.{
            .{ .coords = coords, .subscription_id = 2, .mesh_revision = 8, .data = .{ .boundaries = @splat(.{}) } },
            .{ .coords = coords, .subscription_id = 1, .mesh_revision = 100, .data = .{ .boundaries = @splat(.{}) } },
        });
        try std.testing.expectEqual(9, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    }
}

test "fresh remote masks override unsubscribed blocks retained during neighbor demotion" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.subscribe(neighbor, 2, .blocks);
    try fixture.game.world.?.insertChunk(coords, singleTestBlock(.{ 31, 8, 8 }, 0));
    try fixture.game.world.?.insertChunk(neighbor, singleTestBlock(.{ 0, 8, 8 }, 0));
    fixture.game.loadChunkIfNeeded(1, 1, 1);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(0, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try fixture.subscribe(neighbor, 3, .mesh);
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .boundaries = @splat(.{}) } }});
    fixture.game.rebuildDirtyChunks();
    try std.testing.expect(fixture.game.world.?.hasChunk(neighbor));
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "boundary changes opposite air retain masks without rebuilding and affect later optimistic placement" {
    for (std.enums.values(Side)) |side| {
        var fixture: StreamingTest = .{};
        fixture.init();
        defer fixture.deinit();
        const coords = ChunkCoords{ 2, 2, 2 };
        const id = test_layout.encodeChunkCoords(coords);
        const i = @intFromEnum(side);
        const axis = i / 2;
        var local = [3]u5{ 8, 11, 15 };
        local[axis] = if (i % 2 == 0) 0 else consts.CHUNK_SIZE - 1;
        var opposite_air = local;
        opposite_air[(axis + 1) % 3] = 18;
        var masks: world_engine.BoundaryMasks = @splat(.{});
        masks[i].set(side, opposite_air, true);
        try fixture.subscribe(coords, 1, .blocks);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(local, 0), .neighbors = masks } } }});
        fixture.game.rebuildDirtyChunks();
        const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr;
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);

        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
        try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
        try std.testing.expectEqual(2, fixture.game.boundary_snapshots.get(id).?.mesh_revision);
        try std.testing.expect(!fixture.game.boundary_snapshots.get(id).?.masks[i].contains(side, opposite_air));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr);

        // This placement must use the updated plane even though no rebuild accompanied it.
        const block = [3]u32{
            @as(u32, @intCast(coords[0])) * consts.CHUNK_SIZE + opposite_air[0],
            @as(u32, @intCast(coords[1])) * consts.CHUNK_SIZE + opposite_air[1],
            @as(u32, @intCast(coords[2])) * consts.CHUNK_SIZE + opposite_air[2],
        };
        fixture.game.world.?.setBlock(block, .dirt);
        fixture.game.markChunksAroundBlockDirty(block);
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(2, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);

        masks[i].set(side, opposite_air, false);
        masks[i].set(side, local, true);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 3, .data = .{ .boundaries = masks } }});
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
        try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 4, .data = .{ .boundaries = @splat(.{}) } }});
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(id));
        fixture.game.rebuildDirtyChunks();
        try std.testing.expectEqual(2, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
    }
}

test "authoritative fallback changes do not rebuild faces supplied by an optimistic local neighbor" {
    var fixture: StreamingTest = .{};
    fixture.init();
    defer fixture.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    const neighbor = ChunkCoords{ 2, 1, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    const i = @intFromEnum(Side.right);
    var masks: world_engine.BoundaryMasks = @splat(.{});
    masks[i].set(.right, .{ 31, 8, 8 }, true);
    try fixture.subscribe(coords, 1, .blocks);
    try fixture.subscribe(neighbor, 2, .blocks);
    try fixture.game.world.?.insertChunk(neighbor, singleTestBlock(.{ 0, 8, 8 }, 0));
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 1, .data = .{ .blocks = .{ .chunk = singleTestBlock(.{ 31, 8, 8 }, 0), .neighbors = masks } } }});
    fixture.game.rebuildDirtyChunks();
    const edited = [3]u32{ 2 * consts.CHUNK_SIZE, consts.CHUNK_SIZE + 8, consts.CHUNK_SIZE + 8 };
    fixture.game.world.?.setBlock(edited, .none);
    fixture.game.markChunksAroundBlockDirty(edited);
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(1, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.len);
    const original_faces = fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr;
    try fixture.apply(&.{.{ .coords = coords, .subscription_id = 1, .mesh_revision = 2, .data = .{ .boundaries = @splat(.{}) } }});
    try std.testing.expect(!fixture.game.dirty_chunk_ids.contains(id));
    try std.testing.expect(!fixture.game.boundary_snapshots.get(id).?.masks[i].contains(.right, .{ 31, 8, 8 }));
    fixture.game.rebuildDirtyChunks();
    try std.testing.expectEqual(original_faces, fixture.grid.chunks_to_upload.items[0].chunk_side_data.blocks_grouped_by_side[i].items.ptr);
}

test "different runtime layouts stream, edit, and evict across their own x seams" {
    const layouts = [_]WorldLayout{
        try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 } }),
        try WorldLayout.init(.{ .size_in_chunks = .{ 256, 128, 4 } }),
    };
    const first_service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layouts[0], .flat);
    defer first_service.destroy();
    const second_service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layouts[1], .flat);
    defer second_service.destroy();
    for ([_]*WorldDataService{ first_service, second_service }) |service| {
        const layout = service.layout;
        var fixture: StreamingTest = .{};
        fixture.initWithLayout(layout);
        defer fixture.deinit();
        fixture.game.world_client = try service.createClient();
        const half_width: f64 = @floatFromInt(layout.size_in_blocks[0] / 2);
        fixture.camera.position[0] = -half_width + 0.5;
        fixture.game.updateChunksAroundCamera(false);
        try fixture.drainUntilSettled();
        const expected_z: usize = @intCast(@min(layout.size_in_chunks[2], 7));
        try std.testing.expectEqual(49 * expected_z, fixture.game.chunk_subscriptions.count());
        try std.testing.expectEqual(27, fixture.game.world.?.chunks.count());
        const origin = layout.origin_chunk;
        const local = ChunkCoords{ 0, origin[1], origin[2] };
        const neighbor = ChunkCoords{ layout.size_in_chunks[0] - 1, origin[1], origin[2] };
        try std.testing.expect(fixture.game.world.?.hasChunk(local));
        try std.testing.expect(fixture.game.world.?.hasChunk(neighbor));
        const block = [3]u32{ 0, @as(u32, @intCast(origin[1])) * consts.CHUNK_SIZE + 8, @as(u32, @intCast(origin[2])) * consts.CHUNK_SIZE + 8 };
        fixture.game.world.?.setBlock(block, .dirt);
        fixture.game.markChunksAroundBlockDirty(block);
        fixture.game.flushBlockOperations();
        try std.testing.expect(fixture.game.dirty_chunk_ids.contains(layout.encodeChunkCoords(neighbor)));
        fixture.camera.position[0] -= 1;
        fixture.game.updateChunksAroundCamera(false);
        try std.testing.expectEqual(layout.size_in_chunks[0] - 1, fixture.game.last_camera_chunk_coords.?[0]);
        try fixture.drainUntilSettled();
        try std.testing.expect(try fixture.game.world.?.isBlockSolid(block));
        fixture.camera.position[0] = 0;
        fixture.game.updateChunksAroundCamera(false);
        try fixture.drainUntilSettled();
        try std.testing.expect(!fixture.game.world.?.hasChunk(local));
        try std.testing.expect(!fixture.game.chunk_subscriptions.contains(layout.encodeChunkCoords(neighbor)));
    }
}
