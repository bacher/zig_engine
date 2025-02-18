const std = @import("std");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const content_dir = @import("build_options").content_dir;

const WindowContext = @import("./engine/glue.zig").WindowContext;
// BUG: if put "Engine.zig" instead of "engine.zig" imports get broken
// const Engine = @import("./engine/Engine.zig").Engine;
const Engine = @import("./engine/engine.zig").Engine;

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

    const engine = try Engine.init(allocator, window_context, content_dir, .{
        .onUpdate = onUpdate,
        .onRender = onRender,
    });
    defer engine.deinit();

    const man_model_id = try engine.loadModel("man/man.gltf");

    var window_block_model = try engine.loadWindowBoxModel("window-block/wb-pattern.png");
    // TODO: Move cleanup to the engine
    defer {
        window_block_model.deinit(engine.gctx);
        allocator.destroy(window_block_model);
    }

    const scene = try engine.createScene();
    defer scene.deinit();

    scene.camera.updatePosition(.{ 0.5, -2, 0.5 });

    // _ = man_model_id;

    const game_object = try scene.addObject(.{
        .model_id = man_model_id,
        .position = .{ -2, 0, 0 },
    });
    _ = game_object;

    // const game_object_2 = try scene.addObject(.{
    //     .model_id = man_model_id,
    //     .position = .{ 2, 0, 0 },
    // });
    // _ = game_object_2;

    const window_block_object = try scene.addWindowBoxObject(.{
        .model = window_block_model,
        .position = .{ 0, 0, 0 },
    });
    _ = window_block_object;

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

fn onUpdate(engine: *Engine) void {
    _ = engine;

    // zgui.backend.newFrame(
    //     engine.gctx.swapchain_descriptor.width,
    //     engine.gctx.swapchain_descriptor.height,
    // );
    // zgui.showDemoWindow(null);
}

fn onRender(engine: *Engine, pass: wgpu.RenderPassEncoder) void {
    _ = engine;
    _ = pass;

    // zgui.backend.draw(pass);
}
