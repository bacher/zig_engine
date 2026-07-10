const std = @import("std");
const math = std.math;
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const Engine = @import("./engine.zig").Engine;

pub fn zguiInit(
    allocator: std.mem.Allocator,
    window: *zglfw.Window,
    device: wgpu.Device,
    content_dir: []const u8,
) void {
    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(allocator);
    errdefer zgui.deinit();

    const font_path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ content_dir, "Roboto-Medium.ttf" }, 0) catch @panic("OOM");
    defer allocator.free(font_path);

    _ = zgui.io.addFontFromFile(font_path, math.floor(16.0 * scale_factor));

    zgui.backend.init(
        window,
        device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    errdefer zgui.backend.deinit();

    zgui.getStyle().scaleAllSizes(scale_factor);
}

pub fn zguiDeinit() void {
    zgui.backend.deinit();
    zgui.deinit();
}

pub fn beginFrame(width: u32, height: u32) void {
    zgui.backend.newFrame(width, height);
    // zgui.showDemoWindow(null);
}

pub fn drawDebugWindow(engine: *const Engine) void {
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

    const camera = engine.active_scene.?.camera;

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
}

pub fn endFrame(pass: wgpu.RenderPassEncoder) void {
    zgui.backend.draw(pass);
}
