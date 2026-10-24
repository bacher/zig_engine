//! An inset world overview. The terrain texture is built on first use and kept
//! until shutdown; only the two small heading markers change between frames.
const std = @import("std");
const engine = @import("engine");
const zgui = engine.zgui;
const zgpu = engine.zgpu;
const generation = @import("world_generator.zig");
const data = @import("world_map_data.zig");

pub const debug_teleport_enabled = @import("builtin").mode == .Debug;
pub const Pose = struct { position: engine.world_math.Position, yaw: f32 };
pub const View = struct { player: ?Pose = null, spectator: ?Pose = null, teleport_status: ?[]const u8 = null };
pub const Action = struct { close: bool = false, teleport_xy: ?[2]f64 = null };

const player_color = [4]f32{ 1, 0.85, 0.36, 1 };
const spectator_color = [4]f32{ 0.34, 0.87, 1, 1 };

pub const State = struct {
    texture: ?engine.TextureDescriptor = null,
    failed: bool = false,

    pub fn deinit(self: *State, gctx: *zgpu.GraphicsContext) void {
        if (self.texture) |texture| texture.deinit(gctx);
        self.* = .{};
    }

    /// M/Escape are handled before gameplay input is dispatched. A Debug map
    /// click requests teleportation without closing the panel.
    pub fn draw(self: *State, allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, prepared: *const generation.PreparedWorldGenerator, view: View) Action {
        if (self.texture == null and !self.failed) {
            self.prepare(allocator, gctx, prepared) catch |err| {
                self.failed = true;
                std.log.err("world map: {s}", .{@errorName(err)});
            };
        }
        const texture_ref: ?zgui.TextureRef = if (self.texture) |texture|
            .{ .tex_data = null, .tex_id = @enumFromInt(@intFromPtr(texture.view)) }
        else
            null;
        return drawPanel(texture_ref, prepared.layout, view);
    }

    fn prepare(self: *State, allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, prepared: *const generation.PreparedWorldGenerator) !void {
        var raster = try data.Raster.init(allocator, prepared);
        defer raster.deinit(allocator);
        const texture_handle = gctx.createTexture(.{
            .label = "World map",
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{ .width = raster.width, .height = raster.height, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
        });
        errdefer gctx.destroyResource(texture_handle);
        const view_handle = gctx.createTextureView(texture_handle, .{});
        errdefer gctx.releaseResource(view_handle);
        const texture = gctx.lookupResource(texture_handle) orelse return error.MapTextureUnavailable;
        const texture_view = gctx.lookupResource(view_handle) orelse return error.MapTextureUnavailable;
        gctx.queue.writeTexture(
            .{ .texture = texture },
            .{ .bytes_per_row = raster.width * 4, .rows_per_image = raster.height },
            .{ .width = raster.width, .height = raster.height },
            u8,
            raster.pixels,
        );
        self.texture = .{ .texture_handle = texture_handle, .texture = texture, .view_handle = view_handle, .view = texture_view };
    }
};

const Rect = struct {
    position: [2]f32,
    size: [2]f32,

    fn max(self: Rect) [2]f32 {
        return .{ self.position[0] + self.size[0], self.position[1] + self.size[1] };
    }
};

const Panel = struct { window: Rect, map: Rect, padding: f32, scale: f32 };

fn panelLayout(screen: [2]f32, world_size: [2]u32, scale: f32) ?Panel {
    const margin = @min(48 * scale, @min(screen[0], screen[1]) * 0.06);
    const padding = 18 * scale;
    const header = 40 * scale;
    const footer = (if (debug_teleport_enabled) @as(f32, 56) else 34) * scale;
    const available: [2]f32 = .{ screen[0] - 2 * (margin + padding), screen[1] - 2 * (margin + padding) - header - footer };
    if (available[0] < 120 * scale or available[1] < 1) return null;
    const aspect = @as(f32, @floatFromInt(world_size[0])) / @as(f32, @floatFromInt(world_size[1]));
    const map_width = @min(@min(available[0], available[1] * aspect), 1280 * scale);
    const map_height = map_width / aspect;
    const size: [2]f32 = .{ @min(available[0] + padding * 2, @max(map_width + padding * 2, 300 * scale)), map_height + header + footer + padding * 2 };
    const position: [2]f32 = .{ (screen[0] - size[0]) / 2, (screen[1] - size[1]) / 2 };
    return .{
        .window = .{ .position = position, .size = size },
        .map = .{ .position = .{ (screen[0] - map_width) / 2, position[1] + padding + header }, .size = .{ map_width, map_height } },
        .padding = padding,
        .scale = scale,
    };
}

fn drawPanel(texture: ?zgui.TextureRef, layout: *const engine.WorldLayout, view: View) Action {
    const screen = zgui.io.getDisplaySize();
    const scale = zgui.getStyle().font_scale_dpi;
    const panel = panelLayout(screen, .{ layout.size_in_blocks[0], layout.size_in_blocks[1] }, scale) orelse return .{};
    zgui.setNextWindowPos(.{ .x = panel.window.position[0], .y = panel.window.position[1] });
    zgui.setNextWindowSize(.{ .w = panel.window.size[0], .h = panel.window.size[1] });
    zgui.setNextWindowFocus();
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = .{ 0.075, 0.105, 0.125, 1 } });
    defer zgui.popStyleColor(.{});
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    defer zgui.popStyleVar(.{});
    _ = zgui.begin("World map", .{ .flags = .{
        .no_title_bar = true,
        .no_move = true,
        .no_resize = true,
        .no_collapse = true,
        .no_saved_settings = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
    } });
    defer zgui.end();
    const draw = zgui.getWindowDrawList();
    const title: [2]f32 = .{ panel.window.position[0] + panel.padding, panel.window.position[1] + panel.padding + 5 * scale };
    const right = panel.window.max()[0] - panel.padding;
    draw.addTextUnformatted(title, color(.{ 0.94, 0.96, 0.97, 1 }), "World map");
    draw.addTextUnformatted(.{ right - 122 * scale, title[1] }, color(.{ 0.7, 0.77, 0.8, 1 }), "N");
    zgui.setCursorScreenPos(.{ right - 96 * scale, panel.window.position[1] + panel.padding });
    var action: Action = .{ .close = zgui.button("Close  [M]", .{ .w = 96 * scale, .h = 28 * scale }) };

    if (texture) |image| {
        draw.addImage(image, .{ .pmin = panel.map.position, .pmax = panel.map.max() });
        if (debug_teleport_enabled) {
            zgui.setCursorScreenPos(panel.map.position);
            _ = zgui.invisibleButton("Debug map teleport", .{ .w = panel.map.size[0], .h = panel.map.size[1] });
            // IsItemClicked fires on the press edge, without button repeat or
            // release activation. The item bounds exclude the surrounding gutter.
            if (!action.close and zgui.isItemClicked(.left)) {
                const mouse = zgui.getMousePos();
                action.teleport_xy = data.unprojectTeleport(layout, .{
                    @as(f64, mouse[0] - panel.map.position[0]) / panel.map.size[0],
                    @as(f64, mouse[1] - panel.map.position[1]) / panel.map.size[1],
                });
            }
            draw.addTextUnformatted(.{ title[0], panel.map.max()[1] + 34 * scale }, color(.{ 0.7, 0.77, 0.8, 1 }), view.teleport_status orelse "Debug: Mouse1 to teleport");
        }
    } else {
        draw.addRectFilled(.{ .pmin = panel.map.position, .pmax = panel.map.max(), .col = color(.{ 0.12, 0.17, 0.2, 1 }) });
        draw.addTextUnformatted(.{ panel.map.position[0] + 16 * scale, panel.map.position[1] + 16 * scale }, color(.{ 1, 1, 1, 1 }), "World map unavailable");
    }
    draw.addRect(.{ .pmin = panel.map.position, .pmax = panel.map.max(), .col = color(.{ 0.45, 0.53, 0.55, 1 }), .thickness = scale });

    // Keep the centre at its exact geographic position, even at the X seam.
    // The padded gutter holds the whole glyph when it straddles a map edge.
    // The larger original marker remains visible behind a spectator at the same
    // location, including immediately after switching control modes.
    if (view.player) |pose| drawMarker(draw, panel.map, data.projectMarker(layout, pose.position, pose.yaw), player_color, if (view.spectator != null) 0.6 else 1, (if (view.spectator != null) @as(f32, 12) else 10) * scale);
    if (view.spectator) |pose| drawMarker(draw, panel.map, data.projectMarker(layout, pose.position, pose.yaw), spectator_color, 1, 8 * scale);

    const legend_y = panel.map.max()[1] + 18 * scale;
    if (view.player != null) {
        drawLegend(draw, .{ title[0] + 6 * scale, legend_y }, player_color, if (view.spectator != null) 0.6 else 1, "Player", scale);
    }
    if (view.spectator != null) drawLegend(draw, .{ title[0] + 128 * scale, legend_y }, spectator_color, 1, "Spectator", scale);
    return action;
}

fn color(value: [4]f32) u32 {
    return zgui.colorConvertFloat4ToU32(value);
}

fn drawMarker(draw: zgui.DrawList, rect: Rect, marker: data.Marker, tint: [4]f32, alpha: f32, radius: f32) void {
    const centre: [2]f32 = .{ rect.position[0] + marker.uv[0] * rect.size[0], rect.position[1] + marker.uv[1] * rect.size[1] };
    arrow(draw, centre, marker.direction, tint, alpha, radius);
}

fn arrow(draw: zgui.DrawList, centre: [2]f32, direction: [2]f32, tint: [4]f32, alpha: f32, radius: f32) void {
    const side: [2]f32 = .{ -direction[1], direction[0] };
    const tip: [2]f32 = .{ centre[0] + direction[0] * radius, centre[1] + direction[1] * radius };
    const left: [2]f32 = .{ centre[0] - direction[0] * radius * 0.65 + side[0] * radius * 0.65, centre[1] - direction[1] * radius * 0.65 + side[1] * radius * 0.65 };
    const right: [2]f32 = .{ centre[0] - direction[0] * radius * 0.65 - side[0] * radius * 0.65, centre[1] - direction[1] * radius * 0.65 - side[1] * radius * 0.65 };
    var fill = tint;
    fill[3] *= alpha;
    draw.addCircleFilled(.{ .p = centre, .r = radius + 3, .col = color(.{ 0.02, 0.04, 0.06, 0.65 * alpha }) });
    draw.addTriangleFilled(.{ .p1 = tip, .p2 = left, .p3 = right, .col = color(fill) });
    draw.addTriangle(.{ .p1 = tip, .p2 = left, .p3 = right, .col = color(.{ 1, 1, 1, 0.9 * alpha }), .thickness = 1.5 });
}

fn drawLegend(draw: zgui.DrawList, position: [2]f32, tint: [4]f32, alpha: f32, label: []const u8, scale: f32) void {
    arrow(draw, position, .{ 0, -1 }, tint, alpha, 5 * scale);
    draw.addTextUnformatted(.{ position[0] + 14 * scale, position[1] - 8 * scale }, color(.{ 0.85, 0.89, 0.9, alpha }), label);
}

test "world map panel keeps margins and true aspect across window shapes and UI scales" {
    for ([_][2]f32{ .{ 1280, 820 }, .{ 1920, 1080 }, .{ 820, 1280 }, .{ 320, 240 } }) |screen| {
        for ([_][2]u32{ .{ 65536, 32768 }, .{ 32768, 65536 }, .{ 8192, 8192 } }) |world_size| {
            for ([_]f32{ 1, 2 }) |scale| {
                const panel = panelLayout(screen, world_size, scale) orelse continue;
                try std.testing.expect(panel.window.position[0] > 0 and panel.window.position[1] > 0);
                try std.testing.expect(panel.window.max()[0] < screen[0] and panel.window.max()[1] < screen[1]);
                try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(world_size[0])) / @as(f32, @floatFromInt(world_size[1])), panel.map.size[0] / panel.map.size[1], 0.000001);
                try std.testing.expect(panel.map.position[0] - panel.window.position[0] >= 13 * scale);
            }
        }
    }
    try std.testing.expectEqual(null, panelLayout(.{ 0, 0 }, .{ 65536, 32768 }, 1));
}

test "world map close button and directional overlays render at normal and Retina density" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    const Probe = struct {
        fn frame(world_layout: *const engine.WorldLayout, view: View) Action {
            zgui.newFrame();
            const action = drawPanel(.{ .tex_data = null, .tex_id = @enumFromInt(1) }, world_layout, view);
            zgui.render();
            return action;
        }
    };
    const view: View = .{ .player = .{ .position = .{ 0, 0, 0 }, .yaw = 0 }, .spectator = .{ .position = .{ 1000, 1000, 0 }, .yaw = 1 } };
    for ([_]f32{ 1, 2 }) |density| {
        zgui.io.setDisplaySize(1280, 820);
        zgui.io.setDisplayFramebufferScale(density, density);
        for (0..3) |_| try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, view));
        try std.testing.expect(zgui.getDrawData().total_vtx_count > 0);
        const panel = panelLayout(.{ 1280, 820 }, .{ 65536, 32768 }, 1).?;
        zgui.io.addMousePositionEvent(panel.map.max()[0] - 48, panel.window.position[1] + panel.padding + 14);
        _ = Probe.frame(&layout, view);
        zgui.io.addMouseButtonEvent(.left, true);
        _ = Probe.frame(&layout, view);
        zgui.io.addMouseButtonEvent(.left, false);
        try std.testing.expectEqualDeep(Action{ .close = true }, Probe.frame(&layout, view));
    }
}

test "world map teleport accepts only Debug terrain presses once at normal and Retina density" {
    zgui.init(std.testing.allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    _ = zgui.io.addFontFromFile("content/Roboto-Medium.ttf", 16);
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 4, 2 } });
    const Probe = struct {
        fn frame(world_layout: *const engine.WorldLayout, available: bool) Action {
            zgui.newFrame();
            const action = drawPanel(if (available) .{ .tex_data = null, .tex_id = @enumFromInt(1) } else null, world_layout, .{});
            zgui.render();
            return action;
        }

        fn press(world_layout: *const engine.WorldLayout, point: [2]f32, available: bool) Action {
            zgui.io.addMouseButtonEvent(.left, false);
            _ = frame(world_layout, available);
            zgui.io.addMousePositionEvent(point[0], point[1]);
            _ = frame(world_layout, available);
            zgui.io.addMouseButtonEvent(.left, true);
            return frame(world_layout, available);
        }
    };
    for ([_]f32{ 1, 2 }) |density| {
        zgui.io.setDisplaySize(1280, 820);
        zgui.io.setDisplayFramebufferScale(density, density);
        const panel = panelLayout(.{ 1280, 820 }, .{ 256, 128 }, 1).?;
        const centre: [2]f32 = .{ panel.map.position[0] + panel.map.size[0] / 2, panel.map.position[1] + panel.map.size[1] / 2 };
        for (0..3) |_| try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));

        const action = Probe.press(&layout, centre, true);
        try std.testing.expectEqualDeep(Action{ .teleport_xy = if (debug_teleport_enabled) .{ 0.5, 0.5 } else null }, action);
        for (0..4) |_| try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));
        zgui.io.addMousePositionEvent(centre[0] + 10, centre[1] + 10);
        try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));
        zgui.io.addMouseButtonEvent(.left, false);
        try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));

        // Right-clicking terrain never emits a request.
        zgui.io.addMouseButtonEvent(.right, true);
        try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));
        zgui.io.addMouseButtonEvent(.right, false);
        try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));

        // Image corners preserve north-up coordinates and block centres.
        for ([_][2]f32{ .{ 0.001, 0.001 }, .{ 0.999, 0.001 }, .{ 0.001, 0.999 }, .{ 0.999, 0.999 } }) |uv| {
            const point: [2]f32 = .{ panel.map.position[0] + uv[0] * panel.map.size[0], panel.map.position[1] + uv[1] * panel.map.size[1] };
            const corner = Probe.press(&layout, point, true);
            const expected = data.unprojectTeleport(&layout, .{
                @as(f64, point[0] - panel.map.position[0]) / panel.map.size[0],
                @as(f64, point[1] - panel.map.position[1]) / panel.map.size[1],
            });
            try std.testing.expectEqualDeep(Action{ .teleport_xy = if (debug_teleport_enabled) expected else null }, corner);
        }

        // Gutter, header, legend, and outside-window clicks cannot teleport.
        for ([_][2]f32{
            .{ panel.map.position[0] - 1, centre[1] },
            .{ panel.map.max()[0] + 1, centre[1] },
            .{ centre[0], panel.map.position[1] - 1 },
            .{ centre[0], panel.map.max()[1] + 1 },
            .{ panel.window.position[0] + panel.padding, panel.window.position[1] + panel.padding },
            .{ panel.window.position[0] + panel.padding, panel.map.max()[1] + 18 },
            .{ 1, 1 },
        }) |point| try std.testing.expectEqualDeep(Action{}, Probe.press(&layout, point, true));

        // Dragging a held button from outside into terrain is not a click.
        zgui.io.addMousePositionEvent(centre[0], centre[1]);
        try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, true));
        try std.testing.expectEqualDeep(Action{}, Probe.press(&layout, centre, false));
        zgui.io.addMouseButtonEvent(.left, false);
        try std.testing.expectEqualDeep(Action{}, Probe.frame(&layout, false));
    }
}
