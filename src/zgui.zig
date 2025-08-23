const std = @import("std");
const math = std.math;
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const content_dir = @import("build_options").content_dir;

pub fn zguiInit(allocator: std.mem.Allocator, window: *zglfw.Window, device: wgpu.Device) void {
    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(allocator);
    errdefer zgui.deinit();

    _ = zgui.io.addFontFromFile(content_dir ++ "/Roboto-Medium.ttf", math.floor(16.0 * scale_factor));

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
