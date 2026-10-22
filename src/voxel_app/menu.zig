const std = @import("std");
const zgui = @import("engine").zgui;

pub const Action = enum { resume_game, exit_game };

pub fn draw(paused: bool) ?Action {
    const screen = zgui.io.getDisplaySize();
    if (paused) {
        zgui.getBackgroundDrawList().addRectFilled(.{
            .pmin = .{ 0, 0 },
            .pmax = screen,
            .col = zgui.colorConvertFloat4ToU32(.{ 0, 0, 0, 0.5 }),
        });
    }
    const scale = zgui.getStyle().font_scale_dpi;
    zgui.setNextWindowPos(.{ .x = screen[0] / 2, .y = screen[1] / 2, .pivot_x = 0.5, .pivot_y = 0.5 });
    zgui.setNextWindowFocus();
    _ = zgui.begin("Game menu", .{ .flags = .{
        .always_auto_resize = true,
        .no_title_bar = true,
        .no_move = true,
        .no_resize = true,
        .no_collapse = true,
        .no_saved_settings = true,
    } });
    defer zgui.end();
    var action: ?Action = null;
    if (zgui.button("Resume", .{ .w = 200 * scale, .h = 40 * scale })) action = .resume_game;
    if (zgui.button("Exit", .{ .w = 200 * scale, .h = 40 * scale })) action = .exit_game;
    return action;
}

test "menu returns game actions at normal and Retina framebuffer density" {
    const Probe = struct {
        fn frame() ?Action {
            zgui.newFrame();
            const action = draw(true);
            zgui.render();
            return action;
        }
        fn click(y: f32) ?Action {
            zgui.io.addMousePositionEvent(640, y);
            _ = frame();
            zgui.io.addMouseButtonEvent(.left, true);
            _ = frame();
            zgui.io.addMouseButtonEvent(.left, false);
            return frame();
        }
    };
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    for ([_]f32{ 1, 2 }) |density| {
        zgui.io.setDisplaySize(1280, 820);
        zgui.io.setDisplayFramebufferScale(density, density);
        for (0..3) |_| try std.testing.expectEqual(null, Probe.frame());
        try std.testing.expectEqual(Action.resume_game, Probe.click(388).?);
        try std.testing.expectEqual(Action.exit_game, Probe.click(432).?);
    }
}
