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

const Game = struct {
    saved_game_objects: std.StringHashMap(*GameObject),
};

pub fn main() !void {
    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window_context = try WindowContext.init(allocator);
    defer window_context.deinit();

    const game = try allocator.create(Game);
    game.* = .{
        .saved_game_objects = std.StringHashMap(*GameObject).init(allocator),
    };
    defer {
        game.saved_game_objects.deinit();
        allocator.destroy(game);
    }

    const engine = try Engine.init(allocator, window_context, content_dir, .{
        .argument = game,
        .onUpdate = onUpdate,
        .onRender = onRender,
    });
    defer engine.deinit();

    const man_model_id = id: {
        const loader = try engine.initLoader("man/man.gltf");
        defer loader.deinit();

        const object = loader.findFirstObjectWithMesh().?;
        break :id try engine.loadModel(&loader, object);
    };

    const gazebo_model_id = ids: {
        const loader = try engine.initLoader("toontown-central/scene.gltf");
        defer loader.deinit();

        const gazebo = try loader.getObjectByName("ttc_gazebo_11");
        const gazebo_mesh = loader.findFirstObjectWithMeshNested(gazebo).?;
        const gazebo_model_id = try engine.loadModel(&loader, gazebo_mesh);

        break :ids .{gazebo_model_id};
    };

    const scene = try engine.createScene();
    defer scene.deinit();

    scene.camera.updatePosition(.{ 0, -2, 0 });

    // Skybox (old)

    // const skybox_model = try engine.loadSkyBoxModel("skybox/cubemaps_skybox.png");
    // defer skybox_model.deinit(engine.gctx);
    // defer allocator.destroy(skybox_model);

    // _ = try scene.addSkyBoxObject(.{
    //     .model = skybox_model,
    // });

    // Skybox (cubemap)

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

    _ = try scene.addSkyBoxCubemapObject(.{
        .model = skybox_cubemap_model,
    });

    // ---

    {
        const loader = try engine.initLoader("toontown-central/scene.gltf");
        defer loader.deinit();

        const root_group = try scene.addGroup();
        try traverseGroup(engine, scene, root_group, loader, loader.root, 0);
    }

    var window_block_model = try engine.loadWindowBoxModel("window-block/wb-texture.png");
    // TODO: Move cleanup to the engine
    defer {
        window_block_model.deinit(engine.gctx);
        allocator.destroy(window_block_model);
    }

    try game.saved_game_objects.put("man_1", try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ -2, 0, 0 },
    }));

    try game.saved_game_objects.put("man_2", try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ 4, 0, 0 },
    }));

    _ = gazebo_model_id;
    // try game.saved_game_objects.put("gazebo", try scene.addObject(.{
    //     .model_id = gazebo_model_id,
    //     .position = .{ 0, 0, 0 },
    // }));

    const window_box_1 = try scene.addWindowBoxObject(.{
        .model = window_block_model,
        .position = .{ -2, 2, 0 },
    });
    window_box_1.rotation = zmath.quatFromRollPitchYaw(0.5 * math.pi, 0, 0);

    const window_box_far = try scene.addWindowBoxObject(.{
        .model = window_block_model,
        .position = .{ -1, 10, 1 },
    });
    window_box_far.rotation = zmath.quatFromRollPitchYaw(0.65 * math.pi, 0, 0);

    for (0..6) |z| {
        for (0..2) |x| {
            const size = 3;
            const window_box = try scene.addWindowBoxObject(.{
                .model = window_block_model,
                .position = .{
                    @floatFromInt(2 + x * size),
                    6,
                    @floatFromInt(z * size),
                },
            });
            window_box.scale = size;
            window_box.rotation = zmath.quatFromRollPitchYaw(0.5 * math.pi, 0, 0);
        }
    }

    var tube_data = try tube.initUnitTube(allocator);
    defer tube_data.deinit(allocator);
    var tube_model = try engine.loadPrimitive(tube_data);
    defer {
        tube_model.deinit(engine.gctx);
        allocator.destroy(tube_model);
    }

    // Coordinates

    const tube_x = try scene.addPrimitiveObject(.{
        .model = tube_model,
        .position = .{ 0.5 + tube.M, 0, 0 },
    });
    tube_x.debug.color = .{ 1, 0, 0, 1 };

    const tube_y = try scene.addPrimitiveObject(.{
        .model = tube_model,
        .position = .{ 0, 0.5 + tube.M, 0 },
    });
    tube_y.rotation = zmath.quatFromAxisAngle(.{ 0, 0, 1, 0 }, math.pi / 2.0);
    tube_y.debug.color = .{ 0, 1, 0, 1 };

    const tube_z = try scene.addPrimitiveObject(.{
        .model = tube_model,
        .position = .{ 0, 0, 0.5 + tube.M },
    });
    tube_z.rotation = zmath.quatFromAxisAngle(.{ 0, 1, 0, 0 }, math.pi / 2.0);
    tube_z.debug.color = .{ 0, 0, 1, 1 };

    // ZGui

    zgui_utils.zguiInit(allocator, window_context.window, engine.gctx.device);
    defer zgui_utils.zguiDeinit();

    // Game loop

    try engine.runLoop();
}

fn onUpdate(engine: *Engine, game_opaque: *anyopaque) void {
    const game: *Game = @alignCast(@ptrCast(game_opaque));

    if (game.saved_game_objects.get("man_1")) |obj| {
        obj.rotation = zmath.quatFromRollPitchYaw(0, 0, @floatCast(engine.time));
    }
    if (game.saved_game_objects.get("man_2")) |obj| {
        obj.rotation = zmath.quatFromRollPitchYaw(0, 0, @floatCast(-engine.time));
    }
}

fn onRender(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    _ = game_opaque;

    zgui.backend.newFrame(
        engine.gctx.swapchain_descriptor.width,
        engine.gctx.swapchain_descriptor.height,
    );
    // zgui.showDemoWindow(null);

    const camera = engine.active_scene.?.camera;

    _ = zgui.begin("Debug", .{});
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
    zgui.text("overall time taken: {d:.3}ms", .{engine.frame_stats.overall_time_taken});
    zgui.text("active nodes: {d}", .{engine.frame_stats.active_space_nodes_count});
    zgui.text("find objects sub-invokes: {d}", .{engine.frame_stats.find_objects_sub_invocations_count});
    zgui.endGroup();

    zgui.end();

    zgui.backend.draw(pass);
}

fn traverseGroup(
    engine: *Engine,
    scene: *Scene,
    parent_group: *GameObjectGroup,
    loader: gltf_loader.GltfLoader,
    node: gltf_loader.SceneObject,
    nesting_level: u32,
) !void {
    if (node.children != null) {
        const group = try parent_group.addGroup();

        if (node.transform_matrix) |node_matrix| {
            group.aggregated_mat = zmath.mul(
                parent_group.aggregated_mat,
                loader_utils.convertMatFromUpYToZ(zmath.matFromArr(node_matrix.*)),
            );
        } else {
            group.aggregated_mat = parent_group.aggregated_mat;
        }

        // +DEBUG
        if (node.name != null and std.mem.eql(u8, node.name.?, "ttc_gazebo_11")) {
            std.debug.print("Group lvl={d}: {s}\n", .{ nesting_level, node.name orelse "empty" });
        }
        // -DEBUG

        for (node.children.?) |child| {
            try traverseGroup(engine, scene, group, loader, child, nesting_level + 1);
        }
    } else if (node.mesh != null) {
        const model_id = try engine.loadModel(&loader, &node);

        // Assuming that nodes with mesh can't also have transform_matrix
        std.debug.assert(node.transform_matrix == null);

        std.debug.print("adding model {s}\n", .{node.name orelse "no name"});
        const game_object = try scene.addObject(.{
            .model_id = model_id,
            .position = .{ 0, 0, 0 },
        });
        try parent_group.addObject(game_object);
    }
}
