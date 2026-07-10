const std = @import("std");
const math = std.math;
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

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
