const std = @import("std");
const zmath = @import("zmath");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const gltf_loader = @import("gltf_loader");
const content_dir = @import("build_options").content_dir;

const WindowContext = @import("./engine/glue.zig").WindowContext;
// BUG: if put "Engine.zig" instead of "engine.zig" imports get broken
// const Engine = @import("./engine/Engine.zig").Engine;
const Engine = @import("./engine/engine.zig").Engine;
const GameObject = @import("./engine/game_object.zig").GameObject;
const GameObjectGroup = @import("./engine/game_object_group.zig").GameObjectGroup;
const Scene = @import("./engine/scene.zig").Scene;
const debug = @import("./engine/debug.zig");

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

    const model_id, const gazebo_model_id = ids: {
        const loader = try engine.initLoader("toontown-central/scene.gltf");
        defer loader.deinit();

        const object = loader.findFirstObjectWithMesh().?;
        const model_id = try engine.loadModel(&loader, object);

        const gazebo = try loader.getObjectByName("ttc_gazebo_11");
        const gazebo_mesh = loader.findFirstObjectWithMeshNested(gazebo).?;
        const gazebo_model_id = try engine.loadModel(&loader, gazebo_mesh);

        break :ids .{ model_id, gazebo_model_id };
    };

    const scene = try engine.createScene();
    defer scene.deinit();

    scene.camera.updatePosition(.{ 0, -2, 0 });

    {
        const loader = try engine.initLoader("toontown-central/scene.gltf");
        defer loader.deinit();

        const group = try scene.addGroup();
        if (loader.root.transform_matrix) |matrix| {
            group.aggregated_mat = zmath.matFromArr(matrix.*);
        }
        try traverseGroup(engine, scene, group, loader, loader.root);
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

    // _ = toontown_central_model_id;
    try game.saved_game_objects.put("toontown_1", try scene.addObject(.{
        .model_id = model_id,
        .position = .{ 0, 0, 0 },
    }));

    try game.saved_game_objects.put("gazebo", try scene.addObject(.{
        .model_id = gazebo_model_id,
        .position = .{ 0, 0, 0 },
    }));

    const window_box_1 = try scene.addWindowBoxObject(.{
        .model = window_block_model,
        .position = .{ 0, 0, 0 },
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

    // const scale_factor = scale_factor: {
    //     const scale = window_context.window.getContentScale();
    //     break :scale_factor @max(scale[0], scale[1]);
    // };

    // zgui.init(allocator);
    // defer zgui.deinit();

    // _ = zgui.io.addFontFromFile(content_dir ++ "Roboto-Medium.ttf", math.floor(16.0 * scale_factor));

    // zgui.backend.init(
    //     window_context.window,
    //     engine.gctx.device,
    //     @intFromEnum(zgpu.GraphicsContext.swapchain_format),
    //     @intFromEnum(wgpu.TextureFormat.undef),
    // );
    // defer zgui.backend.deinit();

    // zgui.getStyle().scaleAllSizes(scale_factor);

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

    // zgui.backend.newFrame(
    //     engine.gctx.swapchain_descriptor.width,
    //     engine.gctx.swapchain_descriptor.height,
    // );
    // zgui.showDemoWindow(null);
}

fn onRender(engine: *Engine, pass: wgpu.RenderPassEncoder, game_opaque: *anyopaque) void {
    _ = engine;
    _ = pass;
    _ = game_opaque;

    // zgui.backend.draw(pass);
}

fn traverseGroup(
    engine: *Engine,
    scene: *Scene,
    group: *GameObjectGroup,
    loader: gltf_loader.GltfLoader,
    node: gltf_loader.SceneObject,
) !void {
    if (node.children != null) {
        const sub_group = try group.addGroup();

        if (node.transform_matrix) |node_matrix| {
            sub_group.aggregated_mat = zmath.mul(
                group.aggregated_mat,
                zmath.matFromArr(node_matrix.*),
            );
        } else {
            sub_group.aggregated_mat = group.aggregated_mat;
        }

        for (node.children.?) |child| {
            try traverseGroup(engine, scene, sub_group, loader, child);
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
        try group.addObject(game_object);
    }
}
