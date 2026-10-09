const std = @import("std");
const math = std.math;
const zmath = @import("zmath");
const zgpu = @import("engine").zgpu;
const wgpu = zgpu.wgpu;
const zgui = @import("engine").zgui;
const zglfw = @import("engine").zglfw;
const gltf_loader = @import("gltf_loader");
const content_dir = @import("build_options").content_dir;

const debug = @import("debug");
const WindowContext = @import("engine").WindowContext;
// BUG: if put "Engine.zig" instead of "engine.zig" imports get broken
// const Engine = @import("./engine/Engine.zig").Engine;
const Engine = @import("engine").Engine;
const GameObject = @import("engine").GameObject;
const GameObjectGroup = @import("engine").GameObjectGroup;
const Scene = @import("engine").Scene;
const tube = @import("engine").tube;
const utils = @import("engine").utils;
const world_math = @import("engine").world_math;
const zgui_utils = @import("engine").zgui_utils;

const Game = struct {
    allocator: std.mem.Allocator,
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
        game.allocator.destroy(game);
    }
};

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

    var terrain_textures: std.ArrayList(@import("engine").TextureDescriptor) = .empty;
    defer {
        for (terrain_textures.items) |texture| texture.deinit(window_context.gctx);
        terrain_textures.deinit(allocator);
    }
    try terrain_textures.ensureTotalCapacity(allocator, 3);

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

    // const gazebo_model_id = ids: {
    //     const loader = try engine.initLoader("toontown-central/scene.gltf");
    //     defer loader.deinit();

    //     const gazebo = try loader.getObjectByName("ttc_gazebo_11");
    //     const gazebo_mesh = loader.findFirstObjectWithMeshNested(gazebo).?;
    //     const gazebo_model_id = try engine.loadModel(&loader, gazebo_mesh, .{
    //         .mesh_y_up = true,
    //     });

    //     break :ids .{gazebo_model_id};
    // };

    const scene = try engine.createScene(.{ .size_in_chunks = .{ 512, 256, 8 } });
    defer scene.deinit();

    scene.camera.updatePosition(.{ -2.06, -2.96, 8.45 });
    // scene.camera.updatePosition(.{ -47.69, -13.09, 9.12 });
    // -- look at hydrant closely --
    // scene.camera.updatePosition(.{ -34.92, -8.55, 3.12 });
    // -- look at gazebo closely --
    // scene.camera.updatePosition(.{ -8.94, -30.05, 9.44 });

    // -- Terrain height map --

    const mountains_texture = try engine.loadTexture("content/terrain/rocky-land-and-rivers/diffuse.png", .{
        // TODO: why mipmaps fails?
        .generate_mipmaps = false,
    });

    terrain_textures.appendAssumeCapacity(mountains_texture);
    const mixing_texture = try engine.loadTexture("content/masks/gradient-rough.jpg", .{
        .generate_mipmaps = true,
    });
    terrain_textures.appendAssumeCapacity(mixing_texture);
    const depth_map_texture = try engine.loadTexture("content/terrain/rocky-land-and-rivers/height-map.png", .{
        .forced_num_components = 1,
        .generate_mipmaps = false,
        .format = .r16_uint,
    });
    terrain_textures.appendAssumeCapacity(depth_map_texture);

    const terrain_height_map_model = try engine.createTerrainHeightMapModel(.{
        .layers = .{
            mountains_texture,
            engine.uv_test_texture,
        },
        .mixing_texture = mixing_texture,
        .depth_map_texture = depth_map_texture,
    });

    const terrain = try scene.addTerrainHeightMapObject(.{
        .model = terrain_height_map_model,
        .position = .{ 0, 0, 2.0 },
    });
    terrain.setScale(4);
    // _ = terrain;

    // -- Skybox (old) --

    // const skybox_model = try engine.loadSkyBoxModel("skybox/cubemaps_skybox.png");

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

    _ = try scene.setSkyBoxCubemapObject(.{
        .model = skybox_cubemap_model,
    });

    // ---

    {
        const loader = try engine.initLoader("toontown-central/scene.gltf");
        defer loader.deinit();

        const root_group = try scene.addGroup();
        try traverseGroup(engine, scene, root_group, loader, loader.root, 0, .{});
    }

    const window_block_model = try engine.loadWindowBoxModel("window-block/wb-texture.png");
    _ = window_block_model; // The window-box placement example below is disabled.

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

    // _ = gazebo_model_id;
    // try game.saved_game_objects.put("gazebo", try scene.addObject(.{
    //     .model_id = gazebo_model_id,
    //     .position = .{ 0, 0, 0 },
    // }));

    // -- Window boxes --

    // const window_box_1 = try scene.addWindowBoxObject(.{
    //     .model = window_block_model,
    //     .position = .{ -2, 2, 0 },
    // });
    // window_box_1.rotation = zmath.quatFromRollPitchYaw(0.5 * math.pi, 0, 0);

    // const window_box_far = try scene.addWindowBoxObject(.{
    //     .model = window_block_model,
    //     .position = .{ -1, 10, 1 },
    // });
    // window_box_far.rotation = zmath.quatFromRollPitchYaw(0.65 * math.pi, 0, 0);

    // for (0..6) |z| {
    //     for (0..2) |x| {
    //         const size = 3;
    //         const window_box = try scene.addWindowBoxObject(.{
    //             .model = window_block_model,
    //             .position = .{
    //                 @floatFromInt(2 + x * size),
    //                 6,
    //                 @floatFromInt(z * size),
    //             },
    //         });
    //         window_box.scale = size;
    //         window_box.rotation = zmath.quatFromRollPitchYaw(0.5 * math.pi, 0, 0);
    //     }
    // }

    // -- Tube data for coordinates --

    var tube_data = try tube.initUnitTube(allocator);
    defer tube_data.deinit(allocator);
    const tube_model = try engine.loadPrimitive(tube_data);

    // -- Coordinates --

    {
        const group = try scene.addGroup();

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
}

fn onRender(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    _ = engine;
    _ = pass;
    _ = game_opaque;
}

const GAPS: [8][]const u8 = .{
    "",
    "  ",
    "    ",
    "      ",
    "        ",
    "          ",
    "            ",
    "              ",
};

const DEBUG_TRAVERSE_GROUP = false;
// ttc_trashcan.002_19
// ttc_planter_36
// ttc_hydrant_17
// ttc_hydrant.001_20
// ttc_hydrant.002_21
// ttc_hydrant.003_24
// ttc_trashcan.003_22
// ttc_mailbox.002_23
// ttc_gazebo_11
// tunnel_sign_minnies_melodyland_26
// tunnel_sign_minnies_melodyland.001_27
// tunnel_sign_donalds_dock_28
// tunnel_sign_donalds_dock.001_29
// tunnel_sign_daisy_gardens.001_30
// tunnel_sign_daisy_gardens_31
// fat_tree.001_56
const DRAW_ONLY = "";

fn traverseGroup(
    engine: *Engine,
    scene: *Scene,
    parent_group: *GameObjectGroup,
    loader: gltf_loader.GltfLoader,
    node: gltf_loader.SceneObject,
    nesting_level: u32,
    options: struct {
        is_billboard: bool = false,
    },
) !void {
    if (DRAW_ONLY.len > 0 and nesting_level == 4) {
        if (node.name) |name| {
            if (!std.mem.eql(u8, name, DRAW_ONLY)) {
                return;
            }
        }
    }

    const is_billboard = options.is_billboard or if (nesting_level == 4 and node.name != null)
        std.mem.indexOf(u8, node.name.?, "fat_tree") != null or std.mem.indexOf(u8, node.name.?, "skinny_tree") != null
    else
        false;

    const is_lantern = if (nesting_level == 4 and node.name != null)
        std.mem.indexOf(u8, node.name.?, "ttc_streetlight_lantern") != null
    else
        false;

    const is_lantern_3b = if (nesting_level == 4 and node.name != null)
        std.mem.indexOf(u8, node.name.?, "ttc_streetlight_3bulb") != null
    else
        false;

    if (node.children) |children| {
        const group = try parent_group.addGroup();

        if (node.transform_matrix) |node_matrix| {
            const normalized = utils.convertMatFromUpYToZ(zmath.matFromArr(node_matrix.*));

            const matrix_params = utils.parseTransformMatrix(&normalized);

            group.setSRT(
                .{ matrix_params.position[0], matrix_params.position[1], matrix_params.position[2] },
                matrix_params.rotation,
                matrix_params.scale_scalar,
                parent_group,
            );

            const aggregated_matrix = world_math.matMul(
                parent_group.aggregated_matrix,
                world_math.fromFloat32(normalized),
            );

            for (aggregated_matrix, group.aggregated_matrix) |expected, actual| {
                std.debug.assert(@reduce(.And, @abs(expected - actual) < @as(world_math.Vec, @splat(0.001))));
            }
        } else {
            group.setParent(parent_group);
        }

        if (DEBUG_TRAVERSE_GROUP) {
            std.debug.print("{s}group {s}\n", .{ GAPS[nesting_level], node.name orelse "<no name>" });
        }

        for (children, 0..) |child, index| {
            try traverseGroup(engine, scene, group, loader, child, nesting_level + 1, .{
                .is_billboard = is_billboard or ((is_lantern or is_lantern_3b) and index == 0),
            });
        }
    } else if (node.mesh) |_| {
        const model_id = try engine.loadModel(&loader, &node, .{
            .mesh_y_up = true,
            .billboard_mode = if (is_billboard) .cylindrical else .none,
        });

        // Assuming that nodes with mesh can't also have transform_matrix
        std.debug.assert(node.transform_matrix == null);

        if (DEBUG_TRAVERSE_GROUP) {
            std.debug.print("{s}model {s}\n", .{ GAPS[nesting_level], node.name orelse "<no name>" });
        }
        // model Object_225
        // model Object_226
        // model Object_227
        // model Object_228
        // if (std.mem.eql(u8, node.name orelse "", "Object_324")) {
        _ = try scene.addObject(.{
            .model_id = model_id,
            .position = .{ 0, 0, 0 },
            .parent = parent_group,
        });
        // }
    }
}
