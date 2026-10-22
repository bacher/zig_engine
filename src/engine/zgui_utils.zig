const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const Engine = @import("./engine.zig").Engine;

pub const DpiScaling = struct {
    base_style: zgui.Style,
    scale: f32 = 0,

    pub fn init() DpiScaling {
        var style = zgui.getStyle().*;
        style.font_size_base = 16;
        return .{ .base_style = style };
    }

    pub fn update(self: *DpiScaling, content_scale: [2]f32) void {
        const scale = @max(content_scale[0], content_scale[1]);
        if (scale == self.scale) return;
        // Restore unscaled dimensions so monitor changes cannot accumulate rounding.
        const style = zgui.getStyle();
        style.* = self.base_style;
        style.scaleAllSizes(scale);
        style.font_scale_dpi = scale;
        self.scale = scale;
    }
};

// zgui owns a single context shared by the engine and application overlays.
var dpi_scaling: DpiScaling = undefined;

// Retain GLFW's matching display size, framebuffer density, and mouse units on Retina.
extern fn ImGui_ImplWGPU_NewFrame() void;
extern fn ImGui_ImplGlfw_NewFrame() void;

fn layoutScale(content_scale: [2]f32, window_size: [2]c_int, framebuffer_size: [2]c_int) [2]f32 {
    if (window_size[0] <= 0 or window_size[1] <= 0 or framebuffer_size[0] <= 0 or framebuffer_size[1] <= 0) return .{ 1, 1 };
    return .{
        content_scale[0] * @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(framebuffer_size[0])),
        content_scale[1] * @as(f32, @floatFromInt(window_size[1])) / @as(f32, @floatFromInt(framebuffer_size[1])),
    };
}

fn updateDpi(window: *zglfw.Window) void {
    const content_scale = window.getContentScale();
    dpi_scaling.update(if (@import("builtin").os.tag == .macos)
        layoutScale(content_scale, window.getSize(), window.getFramebufferSize())
    else
        content_scale);
}

pub fn zguiInit(
    allocator: std.mem.Allocator,
    window: *zglfw.Window,
    device: wgpu.Device,
    content_dir: []const u8,
) void {
    zgui.init(allocator);
    errdefer zgui.deinit();

    const font_path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ content_dir, "Roboto-Medium.ttf" }, 0) catch @panic("OOM");
    defer allocator.free(font_path);

    _ = zgui.io.addFontFromFile(font_path, 16);

    zgui.backend.init(
        window,
        device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    errdefer zgui.backend.deinit();

    dpi_scaling = DpiScaling.init();
    updateDpi(window);
}

pub fn zguiDeinit() void {
    zgui.backend.deinit();
    zgui.deinit();
}

pub fn beginFrame(window: *zglfw.Window) void {
    updateDpi(window);
    if (@import("builtin").os.tag == .macos) {
        ImGui_ImplWGPU_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        zgui.newFrame();
    } else {
        const size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(@max(0, size[0])), @intCast(@max(0, size[1])));
    }
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

test "GUI layout scale accounts for framebuffer density on Retina and scaled desktops" {
    try std.testing.expectEqualDeep([2]f32{ 1, 1 }, layoutScale(.{ 2, 2 }, .{ 1280, 800 }, .{ 2560, 1600 }));
    try std.testing.expectEqualDeep([2]f32{ 2, 2 }, layoutScale(.{ 2, 2 }, .{ 1280, 800 }, .{ 1280, 800 }));
    try std.testing.expectEqualDeep([2]f32{ 1, 1 }, layoutScale(.{ 1, 1 }, .{ 1280, 800 }, .{ 1280, 800 }));
    try std.testing.expectEqualDeep([2]f32{ 1, 1 }, layoutScale(.{ 2, 2 }, .{ 0, 0 }, .{ 0, 0 }));
}
