const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

pub const WindowContext = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,
    gctx: *zgpu.GraphicsContext,

    pub fn init(allocator: std.mem.Allocator) !WindowContext {
        try zglfw.init();

        zglfw.windowHint(.client_api, .no_api);

        const window_title = "zig-engine";
        const window = try zglfw.Window.create(800, 600, window_title, null, null);
        errdefer window.destroy();
        window.setSizeLimits(400, 400, -1, -1);

        const gctx = try zgpu.GraphicsContext.create(
            allocator,
            .{
                .window = window,
                .fn_getTime = @ptrCast(&zglfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
                .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
                .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
                .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
                .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
            },
            .{},
        );

        return .{
            .allocator = allocator,
            .window = window,
            .gctx = gctx,
        };
    }

    pub fn deinit(window: WindowContext) void {
        window.gctx.destroy(window.allocator);
        window.window.destroy();
        // window.allocator.free(window);
        zglfw.terminate();
    }
};
