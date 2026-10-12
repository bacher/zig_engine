//! Independent preview hints and short-lived feedback for actual block edits.
const std = @import("std");
const zgui = @import("engine").zgui;
const placement_preview = @import("placement_preview.zig");
const block_diagnostics = @import("block_diagnostics.zig");

pub const action_error_duration: f64 = 4;
const action_outline_color: [4]f32 = .{ 0.02, 0.02, 0.02, 1 };
const action_outline_width: f32 = 1.5;

pub const TimedError = struct {
    buffer: [block_diagnostics.message_capacity]u8 = undefined,
    len: usize = 0,
    expires_at: f64 = 0,

    pub fn show(self: *TimedError, text: []const u8, now: f64) void {
        std.debug.assert(text.len <= self.buffer.len);
        @memcpy(self.buffer[0..text.len], text);
        self.len = text.len;
        self.expires_at = now + action_error_duration;
    }

    pub fn message(self: *const TimedError, now: f64) ?[]const u8 {
        if (self.len == 0 or now >= self.expires_at) return null;
        return self.buffer[0..self.len];
    }
};

pub fn draw(preview: ?placement_preview.Preview, action_error: *const TimedError, now: f64) void {
    const screen = zgui.io.getDisplaySize();
    if (screen[0] <= 0 or screen[1] <= 0) return;
    // The existing zgui backend uses framebuffer pixels and a DPI-scaled 16px font.
    const scale = zgui.getFontSize() / 16;
    var buffer: [block_diagnostics.message_capacity]u8 = undefined;
    if (preview) |current| if (current.errorMessage(&buffer)) |message| {
        drawMessage("##placement-preview-error", message, screen, scale, .preview);
    };
    if (action_error.message(now)) |message| {
        drawMessage("##block-action-error", message, screen, scale, .action);
    }
}

fn drawMessage(name: [:0]const u8, message: []const u8, screen: [2]f32, scale: f32, kind: enum { preview, action }) void {
    const is_preview = kind == .preview;
    // Transparent gutters keep the outline and glyph antialiasing inside the clip rect.
    const padding: [2]f32 = if (is_preview) .{ 12 * scale, 8 * scale } else .{ 4 * scale, 4 * scale };
    const margin = @min(24 * scale, screen[0] * 0.1);
    const max_width = @max(1, @min((if (is_preview) @as(f32, 640) else 840) * scale, screen[0] - 2 * (margin + padding[0])));

    zgui.pushFont(null, (if (is_preview) @as(f32, 14) else 20) * scale);
    defer zgui.popFont();
    const text_size = zgui.calcTextSize(message, .{ .wrap_width = max_width });
    zgui.setNextWindowPos(.{
        .x = screen[0] / 2,
        .y = if (is_preview) screen[1] - @min(28 * scale, screen[1] * 0.1) else @min(48 * scale, screen[1] * 0.1),
        .pivot_x = 0.5,
        .pivot_y = if (is_preview) 1 else 0,
    });
    zgui.setNextWindowSize(.{ .w = @min(text_size[0], max_width) + 2 * padding[0], .h = text_size[1] + 2 * padding[1] });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = padding });
    zgui.pushStyleVar2f(.{ .idx = .window_min_size, .v = .{ 0, 0 } });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 8 * scale });
    zgui.pushStyleVar1f(.{ .idx = .window_border_size, .v = 0 });
    defer zgui.popStyleVar(.{ .count = 4 });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = .{ 0.06, 0.06, 0.06, 0.72 } });
    defer zgui.popStyleColor(.{});

    const visible = zgui.begin(name, .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
        .no_collapse = true,
        .no_background = !is_preview,
        .no_saved_settings = true,
        .no_mouse_inputs = true,
        .no_nav_inputs = true,
        .no_nav_focus = true,
        .no_focus_on_appearing = true,
        .no_bring_to_front_on_focus = true,
    } });
    defer zgui.end();
    if (visible) {
        zgui.pushTextWrapPos(padding[0] + max_width);
        defer zgui.popTextWrapPos();
        if (!is_preview) drawTextOutline(message, max_width, action_outline_width * scale);
        zgui.textUnformattedColored(if (is_preview) .{ 1, 0.65, 0.1, 1 } else .{ 1, 0.15, 0.1, 1 }, message);
    }
}

fn drawTextOutline(message: []const u8, wrap_width: f32, width: f32) void {
    const list = zgui.getWindowDrawList();
    const position = zgui.getCursorScreenPos();
    const color = zgui.colorConvertFloat4ToU32(action_outline_color);
    // Draw behind the normal text without advancing its cursor or changing wrapping.
    for ([_][2]f32{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } }) |offset| {
        list.addTextExtendedUnformatted(.{ position[0] + offset[0] * width, position[1] + offset[1] * width }, color, message, .{
            .font = zgui.getFont(),
            .font_size = zgui.getFontSize(),
            .wrap_width = wrap_width,
        });
    }
}

test "action feedback owns its text and each new failure restarts the timeout" {
    var feedback: TimedError = .{};
    try std.testing.expectEqual(null, feedback.message(0));
    var source = "First failure".*;
    feedback.show(&source, 10);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("First failure", feedback.message(13.9).?);
    try std.testing.expectEqual(null, feedback.message(14));
    feedback.show("New failure", 14);
    try std.testing.expectEqualStrings("New failure", feedback.message(17.9).?);
    try std.testing.expectEqual(null, feedback.message(18));
}

test "both overlays generate visible text inside small and high DPI viewports" {
    for ([_]struct { screen: [2]f32, scale: f32 }{
        .{ .screen = .{ 360, 240 }, .scale = 1 },
        .{ .screen = .{ 1280, 720 }, .scale = 1 },
        .{ .screen = .{ 2560, 1440 }, .scale = 2 },
    }) |viewport| {
        zgui.init(std.testing.allocator);
        defer zgui.deinit();
        zgui.io.setIniFilename(null);
        zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
        _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16 * viewport.scale);
        zgui.io.setDisplaySize(viewport.screen[0], viewport.screen[1]);
        zgui.newFrame();
        const preview: placement_preview.Preview = .{
            .block = .{ 0, 0, 0 },
            .material = .dirt,
            .result = .{ .status = .constraint_violation, .failure = .{
                .reason = .would_invalidate_structure,
                .cause = .earth_footprint,
                .subject = .{ 0, 0, 0 },
                .actual = 1,
                .limit = 9,
            } },
        };
        var buffer: [block_diagnostics.message_capacity]u8 = undefined;
        var feedback: TimedError = .{};
        feedback.show(preview.errorMessage(&buffer).?, 0);
        draw(preview, &feedback, 0);
        zgui.render();
        const data = zgui.getDrawData();
        try std.testing.expectEqual(2, data.cmd_lists_count);
        var found_preview = false;
        var found_action = false;
        for (data.cmd_lists.items[0..@intCast(data.cmd_lists.len)]) |list| {
            const is_preview = std.mem.eql(u8, std.mem.span(list.getOwnerName().?), "##placement-preview-error");
            const color = zgui.colorConvertFloat4ToU32(if (is_preview) .{ 1, 0.65, 0.1, 1 } else .{ 1, 0.15, 0.1, 1 });
            const outline_color = zgui.colorConvertFloat4ToU32(action_outline_color);
            var outlined_vertices: usize = 0;
            var text_vertices: usize = 0;
            for (list.getVertexBuffer()) |vertex| {
                if (vertex.color == outline_color) outlined_vertices += 1;
                if (vertex.color != color) continue;
                text_vertices += 1;
                if (is_preview) found_preview = true else found_action = true;
                try std.testing.expect(vertex.pos[0] >= 0 and vertex.pos[0] <= viewport.screen[0]);
                try std.testing.expect(vertex.pos[1] >= 0 and vertex.pos[1] <= viewport.screen[1]);
            }
            if (is_preview) {
                try std.testing.expectEqual(0, outlined_vertices);
            } else {
                // All eight outline copies retain every glyph across wrapped lines.
                try std.testing.expectEqual(8 * text_vertices, outlined_vertices);
                const vertices = list.getVertexBuffer();
                const indices = list.getIndexBuffer();
                for (list.getCmdBuffer()) |command| {
                    for (indices[command.idx_offset..][0..command.elem_count]) |index| {
                        const vertex = vertices[command.vtx_offset + index];
                        try std.testing.expect(vertex.pos[0] >= command.clip_rect[0] and vertex.pos[0] <= command.clip_rect[2]);
                        try std.testing.expect(vertex.pos[1] >= command.clip_rect[1] and vertex.pos[1] <= command.clip_rect[3]);
                    }
                }
            }
        }
        try std.testing.expect(found_preview and found_action);
    }
}
