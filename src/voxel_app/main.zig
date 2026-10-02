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
const encodeChunkPositionArray = @import("world.zig").encodeChunkPositionArray;
const WorldChunk = @import("world.zig").WorldChunk;
const consts = @import("./consts.zig");
const world_engine = @import("./world_engine_glue.zig");

const DEBUG = true;

const Game = struct {
    allocator: std.mem.Allocator,
    engine: *Engine,
    world: ?World = null,
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
        game.loaded_chunk_ids.deinit(game.allocator);

        game.saved_game_objects.deinit(game.allocator);
        game.saved_game_object_groups.deinit(game.allocator);
        if (game.world) |*world| {
            world.deinit();
        }
        game.engine.deinit();
        game.allocator.destroy(game);
    }

    pub fn updateChunksAroundCamera(game: *Game) void {
        if (game.world == null) {
            return;
        }

        const engine = game.engine;
        const voxel_grid = engine.active_scene.?.voxel_grid;

        const camera_position = engine.active_scene.?.camera.position;

        const camera_chunk_coords = chunk_utils.getChunkCoords(camera_position);

        if (game.last_camera_chunk_coords) |last_camera_chunk_coords| {
            if (@reduce(.And, camera_chunk_coords == last_camera_chunk_coords)) {
                return;
            }
        }

        const camera_box = fitBoxIntoWorld(getBoxAroundChunk(camera_chunk_coords, 2));

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
                            const pos = world_module.normalizeChunkPosition(fixed_x, y, z);
                            game.removeChunkIfNeeded(pos);
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
                            const pos = world_module.normalizeChunkPosition(x, fixed_y, z);
                            game.removeChunkIfNeeded(pos);
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
                            const pos = world_module.normalizeChunkPosition(x, y, fixed_z);
                            game.removeChunkIfNeeded(pos);
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

        std.debug.print("camera_box: {any} <-> {any}\n", .{ camera_box.start, camera_box.end });

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

    fn uploadChunkIfNeeded(game: *Game, chunk_x: i32, chunk_y: i32, chunk_z: i32) void {
        const voxel_grid = game.engine.active_scene.?.voxel_grid;

        const chunk_coords = world_module.normalizeChunkPosition(chunk_x, chunk_y, chunk_z);
        const chunk_id = encodeChunkPositionArray(chunk_coords);

        if (game.loaded_chunk_ids.contains(chunk_id)) {
            return;
        }

        const world_chunk = game.world.?.getChunk(chunk_coords);
        if (world_chunk.content == .blocks and !game.checkIfChunkCanBeSkipped(chunk_coords)) {
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

    fn checkIfChunkCanBeSkipped(game: *Game, chunk_coords: [3]u30) bool {
        const surrounding_chunks = getSurroundingChunks(&game.world.?, chunk_coords);

        for (surrounding_chunks, 0..) |surrounding_chunk_opt, side_index| {
            // out of world bounds, nothing can be seen from there
            const surrounding_chunk = surrounding_chunk_opt orelse continue;

            const side = @as(Side, @enumFromInt(side_index));
            if (!surrounding_chunk.flags.getSideSolidness(side.getOpposite())) {
                return false;
            }
        }

        return true;
    }

    fn editBlockUnderCamera(game: *Game, action: BlockAction) void {
        const world = if (game.world) |*world| world else return;

        const camera_position = game.engine.active_scene.?.camera.position;
        const top = getColumnTopUnderPosition(camera_position) orelse return;

        const edited_block = switch (action) {
            .remove => world.removeTopBlockInColumn(top),
            .add_dirt => world.dropBlockInColumn(top, .dirt),
        } orelse return;

        if (DEBUG) {
            std.debug.print("{s} block {any}\n", .{ @tagName(action), edited_block });
        }

        game.reloadChunksAroundBlock(edited_block, action == .remove);
    }

    /// Re-uploads the chunk of the edited block and the neighbor chunks sharing a face with it,
    /// because their visibility depends on the solidness of the chunk sides.
    fn reloadChunksAroundBlock(game: *Game, block: [3]u32, is_block_removed: bool) void {
        const world = &game.world.?;
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

            // Solid chunks have no block data, so the walls of the hole wouldn't be rendered.
            if (is_block_removed and world.getChunk(neighbor_coords).content == .solid) {
                _ = world.ensureChunkData(neighbor_coords);
            }

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

fn initWorld(allocator: std.mem.Allocator, game: *Game) void {
    game.world = World.init(allocator, .{ .terrain = .{ .seed = 12345 } });
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

/// Returns neighbors indexed by `Side`, generating them if needed.
/// `null` means the neighbor is out of world bounds.
pub fn getSurroundingChunks(world: *World, coords: [3]u30) [6]?WorldChunk {
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
            resulting_chunks[@intFromEnum(side)] = world.getChunk(normalized_coords);
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

    initWorld(allocator, game);

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

    game.updateChunksAroundCamera();
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
}
