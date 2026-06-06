const std = @import("std");
const zmath = @import("zmath");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const gltf_loader = @import("gltf_loader");
const content_dir = @import("build_options").content_dir;

const debug = @import("debug");
const WindowContext = @import("./engine/glue.zig").WindowContext;
// BUG: if put "Engine.zig" instead of "engine.zig" imports get broken
// const Engine = @import("./engine/Engine.zig").Engine;
const Engine = @import("./engine/engine.zig").Engine;
const GameObject = @import("./engine/game_object.zig").GameObject;
const GameObjectGroup = @import("./engine/game_object_group.zig").GameObjectGroup;
const Scene = @import("./engine/scene.zig").Scene;
const loader_utils = @import("./loader_utils/utils.zig");
const tube = @import("./engine/shape_generation/tube.zig");
const zgui_utils = @import("./zgui.zig");
const utils = @import("./engine/utils.zig");

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

    const engine = try Engine.init(init.io, allocator, window_context, content_dir, .{
        .argument = game,
        .onUpdate = onUpdate,
        .onRender = onRender,
    });
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

    const scene = try engine.createScene();
    defer scene.deinit();

    scene.camera.updatePosition(.{ 1.06, -2.96, 8.45 });
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

    const terrain_height_map_model = try engine.createTerrainHeightMapModel(.{
        .layers = .{
            mountains_texture,
            engine.uv_test_texture,
        },
        .mixing_texture = try engine.loadTexture("content/masks/gradient-rough.jpg", .{
            .generate_mipmaps = true,
        }),
        .depth_map_texture = try engine.loadTexture("content/terrain/rocky-land-and-rivers/height-map.png", .{
            .forced_num_components = 1,
            .generate_mipmaps = false,
            // https://github.com/zig-gamedev/zgpu/blob/main/src/wgpu.zig#L480
            .format = .r16_uint,
        }),
    });

    defer {
        terrain_height_map_model.deinit(engine.gctx);
        allocator.destroy(terrain_height_map_model);
    }

    const terrain = try scene.addTerrainHeightMapObject(.{
        .model = terrain_height_map_model,
        .position = .{ 0, 0, 2.0 },
    });
    terrain.setScale(4);
    // _ = terrain;

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

    {
        const loader = try engine.initLoader("toontown-central/scene.gltf");
        defer loader.deinit();

        const root_group = try scene.addGroup();
        try traverseGroup(engine, scene, root_group, loader, loader.root, 0, .{});
    }

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

    zgui_utils.zguiInit(allocator, window_context.window, engine.gctx.device);
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
    _ = game_opaque;

    zgui.backend.newFrame(
        engine.gctx.swapchain_descriptor.width,
        engine.gctx.swapchain_descriptor.height,
    );
    // zgui.showDemoWindow(null);

    const camera = engine.active_scene.?.camera;

    _ = zgui.begin("Debug", .{
        .flags = .{
            .always_auto_resize = true,
            .no_saved_settings = true,
            .no_collapse = true,
            .no_mouse_inputs = true,
            .no_focus_on_appearing = true,
            .no_nav_focus = true,
            .no_move = true,
            .no_resize = true,
        },
    });
    zgui.text("camera: {d:2.2}, {d:2.2}, {d:2.2}", .{
        camera.position[0],
        camera.position[1],
        camera.position[2],
    });

    const stats = &engine.gctx.stats;

    zgui.beginGroup();
    zgui.text("Frame stats", .{});
    zgui.text("time: {d:.1}s", .{stats.time});
    zgui.text("fps: {d:.1}", .{stats.fps});
    zgui.text("frame time: {d:.1}ms", .{stats.delta_time * 1000});
    zgui.text("cpu time (avg): {d:.1}", .{stats.average_cpu_time});
    // zgui.text("fps_counter: {d}", .{stats.fps_counter});
    // zgui.text("fps_refresh_time: {d}", .{stats.fps_refresh_time});
    // zgui.text("cpu_frame_number: {d}", .{stats.cpu_frame_number});
    // zgui.text("gpu_frame_number: {d}", .{stats.gpu_frame_number});
    zgui.text("objects drawn: {d}", .{engine.frame_stats.game_objects_drawn_count});
    zgui.text("shadow map pass time taken: {d:.3}ms", .{engine.frame_stats.shadow_map_pass_time_taken});
    zgui.text("main pass time taken: {d:.3}ms", .{engine.frame_stats.main_pass_time_taken});
    zgui.text("active nodes: {d}", .{engine.frame_stats.active_space_nodes_count});
    zgui.text("find objects sub-invokes: {d}", .{engine.frame_stats.find_objects_sub_invocations_count});
    zgui.text("instances written: {d}", .{engine.frame_stats.instances_written_count});
    zgui.endGroup();

    zgui.end();

    zgui.backend.draw(pass);
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
            const normalized = loader_utils.convertMatFromUpYToZ(zmath.matFromArr(node_matrix.*));

            const matrix_params = utils.parseTransformMatrix(&normalized);

            group.setSRT(
                matrix_params.position,
                matrix_params.rotation,
                matrix_params.scale_scalar,
                parent_group,
            );

            const aggregated_matrix = zmath.mul(
                parent_group.aggregated_matrix,
                normalized,
            );

            utils.assertMatricesEqual(&aggregated_matrix, &group.aggregated_matrix);
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
