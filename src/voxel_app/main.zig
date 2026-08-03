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
const GameObject = @import("engine").GameObject;
const GameObjectGroup = @import("engine").GameObjectGroup;
const Scene = @import("engine").Scene;
const voxel_chunk_module = @import("engine").voxel_chunk;
const Side = @import("engine").voxel_chunk.Side;
const tube = @import("engine").tube;
const utils = @import("engine").utils;
const zgui_utils = @import("engine").zgui_utils;

const world_module = @import("world.zig");
const World = @import("world.zig").World;
const encodeChunkPositionArray = @import("world.zig").encodeChunkPositionArray;
const WorldChunk = @import("world.zig").WorldChunk;
const ChunksHashMap = @import("world.zig").ChunksHashMap;
const consts = @import("./consts.zig");
const world_engine = @import("./world_engine_glue.zig");

const Game = struct {
    allocator: std.mem.Allocator,
    world: ?World = null,
    saved_game_objects: std.StringHashMapUnmanaged(*GameObject) = .empty,
    saved_game_object_groups: std.StringHashMapUnmanaged(*GameObjectGroup) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Game {
        const game = try allocator.create(Game);
        game.* = .{
            .allocator = allocator,
        };
        return game;
    }

    pub fn deinit(game: *Game) void {
        game.saved_game_objects.deinit(game.allocator);
        game.saved_game_object_groups.deinit(game.allocator);
        if (game.world) |*world| {
            world.deinit();
        }
        game.allocator.destroy(game);
    }
};

fn initWorld(allocator: std.mem.Allocator, game: *Game) void {
    var world = World.init(allocator);
    world.initFlatWorld();
    game.world = world;
}

pub fn normalizeChunkCoords(coords_in: [3]i32) ?[3]u32 {
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

const SurroundingChunk = union(enum) {
    invalid: bool,
    chunk: ?*const WorldChunk,
};

pub fn getSurroundingChunks(chunks: *const ChunksHashMap, coords: [3]u32) [6]SurroundingChunk {
    const coords_i = [3]i32{ @intCast(coords[0]), @intCast(coords[1]), @intCast(coords[2]) };

    const left_opt = normalizeChunkCoords(.{ coords_i[0] - 1, coords_i[1], coords_i[2] });
    const right_opt = normalizeChunkCoords(.{ coords_i[0] + 1, coords_i[1], coords_i[2] });
    const back_opt = normalizeChunkCoords(.{ coords_i[0], coords_i[1] - 1, coords_i[2] });
    const front_opt = normalizeChunkCoords(.{ coords_i[0], coords_i[1] + 1, coords_i[2] });
    const bottom_opt = normalizeChunkCoords(.{ coords_i[0], coords_i[1], coords_i[2] - 1 });
    const top_opt = normalizeChunkCoords(.{ coords_i[0], coords_i[1], coords_i[2] + 1 });

    const invalid = SurroundingChunk{ .invalid = true };
    var resulting_chunks = [6]SurroundingChunk{ invalid, invalid, invalid, invalid, invalid, invalid };

    if (left_opt) |left| {
        resulting_chunks[@intFromEnum(Side.left)] = .{
            .chunk = chunks.getPtr(encodeChunkPositionArray(left)),
        };
    }
    if (right_opt) |right| {
        resulting_chunks[@intFromEnum(Side.right)] = .{
            .chunk = chunks.getPtr(encodeChunkPositionArray(right)),
        };
    }
    if (back_opt) |back| {
        resulting_chunks[@intFromEnum(Side.back)] = .{
            .chunk = chunks.getPtr(encodeChunkPositionArray(back)),
        };
    }
    if (front_opt) |front| {
        resulting_chunks[@intFromEnum(Side.front)] = .{
            .chunk = chunks.getPtr(encodeChunkPositionArray(front)),
        };
    }
    if (bottom_opt) |bottom| {
        resulting_chunks[@intFromEnum(Side.bottom)] = .{
            .chunk = chunks.getPtr(encodeChunkPositionArray(bottom)),
        };
    }
    if (top_opt) |top| {
        resulting_chunks[@intFromEnum(Side.top)] = .{
            .chunk = chunks.getPtr(encodeChunkPositionArray(top)),
        };
    }

    return resulting_chunks;
}

fn loadChunkMeshData(allocator: std.mem.Allocator, game: *Game, engine: *Engine) void {
    const world = game.world.?;

    for (0..5) |z_world| {
        for (0..5) |y_world| {
            for (0..5) |x_world| {
                const x = (consts.WORLD_ORIGIN[0] - 2) + x_world;
                const y = (consts.WORLD_ORIGIN[1] - 2) + y_world;
                const z = (consts.WORLD_ORIGIN[2] - 2) + z_world;

                const chunk_coords: [3]u32 = .{
                    @intCast(x),
                    @intCast(y),
                    @intCast(z),
                };

                const world_chunk_opt = world.chunks.getPtr(world_module.encodeChunkPositionArray(chunk_coords));

                if (world_chunk_opt) |world_chunk| {
                    std.debug.print("block {} {} {}!\n", .{ x, y, z });
                    std.debug.print("  with data\n", .{});

                    // CHECKING

                    const surrounding_chunks = getSurroundingChunks(&world.chunks, chunk_coords);

                    var can_be_skipped = true;

                    for (surrounding_chunks, 0..) |surrounding_chunk, side_index| {
                        const side = @as(Side, @enumFromInt(side_index));
                        const opposite_side = side.getOpposite();

                        switch (surrounding_chunk) {
                            .chunk => |chunk_opt| {
                                if (chunk_opt) |chunk| {
                                    if (!chunk.flags.getSideSolidness(opposite_side)) {
                                        can_be_skipped = false;
                                        break;
                                    }
                                } else {
                                    // if there is no chunk, it's probably a border of the world, so we can't skip
                                }
                            },
                            .invalid => {
                                // it's okay, meaning we are out of world bounds
                            },
                        }
                    }

                    if (can_be_skipped) {
                        continue;
                    }

                    //

                    var voxel_chunk = voxel_chunk_module.VoxelChunk.init(chunk_coords);
                    world_engine.updateVoxelChunk(allocator, world_chunk, &voxel_chunk);

                    // voxel_chunk.loadTestData(allocator);

                    engine.active_scene.?.voxel_grid.appendChunk(voxel_chunk);
                }
            }
        }
    }
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
        },
    );
    defer engine.deinit();

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
    loadChunkMeshData(allocator, game, engine);

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
}

fn onRender(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    _ = engine;
    _ = pass;
    _ = game_opaque;
}
