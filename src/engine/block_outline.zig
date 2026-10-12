//! Block outlines and translucent cell hints, independent of voxel face rendering.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const Camera = @import("camera.zig").Camera;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const ChunkCoords = @import("world_math.zig").ChunkCoords;
const chunks = @import("chunk_utils.zig");
const utils = @import("utils.zig");
const Pipeline = @import("pipeline.zig").Pipeline;
const BindGroupLayouts = @import("bind_group_layouts.zig").BindGroupLayouts;

pub const vertex_count = 12 * 6;
pub const width_pixels: f32 = 3;
pub const shader = @embedFile("shaders/block_outline.wgsl");
pub const Uniforms = @import("bind_group_layouts/block_outline.zig").Uniforms;
pub const Cell = @Vector(3, i64);
pub const Overlay = struct {
    cell: Cell,
    color: zmath.Vec,
    /// Correct only camera-facing edges of a cell with rendered block surfaces.
    occupied: bool = false,
};

/// Value-owned, allocation-free hints. Applications replace the set each frame.
pub const Overlays = struct {
    cells: [64]Overlay = undefined,
    count: usize = 0,

    pub fn contains(self: *const Overlays, cell: Cell) bool {
        for (self.cells[0..self.count]) |previous| {
            if (@reduce(.And, previous.cell == cell)) return true;
        }
        return false;
    }

    pub fn add(self: *Overlays, overlay: Overlay) void {
        if (self.contains(overlay.cell)) return;
        std.debug.assert(self.count < self.cells.len);
        self.cells[self.count] = overlay;
        self.count += 1;
    }
};

/// Rebase storage coordinates to the camera chunk before narrowing to f32.
pub fn clipFromBlock(camera: *const Camera, block: [3]u32) zmath.Mat {
    return clipFromPosition(camera, blockPosition(camera, .{ block[0], block[1], block[2] }));
}

fn clipFromPosition(camera: *const Camera, position: @Vector(3, f32)) zmath.Mat {
    return utils.matMul(camera.clip_from_world_chunked, zmath.translation(position[0], position[1], position[2]));
}

fn blockPosition(camera: *const Camera, block: Cell) @Vector(3, f32) {
    var chunk: ChunkCoords = undefined;
    var local: @Vector(3, f32) = undefined;
    inline for (0..3) |axis| {
        chunk[axis] = @intCast(@divFloor(block[axis], chunks.CHUNK_SIZE));
        local[axis] = @floatFromInt(@mod(block[axis], chunks.CHUNK_SIZE));
    }
    const delta: @Vector(3, f32) = @floatFromInt(camera.layout.getChunkDelta(chunk, camera.chunk));
    return delta * @as(@Vector(3, f32), @splat(chunks.CHUNK_SIZE)) + local;
}

/// An edge is visible only if at least one of its adjacent faces faces the eye.
pub fn faceMask(eye: @Vector(3, f32)) u32 {
    var mask: u32 = 0;
    inline for (0..3) |axis| {
        if (eye[axis] <= 0) mask |= 1 << (2 * axis);
        if (eye[axis] >= 1) mask |= 1 << (2 * axis + 1);
    }
    // Spectator cameras can enter a block: retain the interior-facing outline.
    return if (mask == 0) 63 else mask;
}

pub fn uniforms(camera: *const Camera, block: [3]u32, viewport: @Vector(2, f32)) Uniforms {
    const position = blockPosition(camera, .{ block[0], block[1], block[2] });
    const transform = clipFromPosition(camera, position);
    const eye = chunks.getLocalPosition(camera.position) - position;
    return .{
        .clip_from_block = transform,
        .block_from_clip = zmath.inverse(transform),
        .stroke = .{ viewport[0], viewport[1], width_pixels, @floatFromInt(faceMask(eye)) },
    };
}

/// All twelve edges remain available. Occupied cells correct only front-facing edges.
pub fn overlayUniforms(camera: *const Camera, overlay: Overlay, viewport: @Vector(2, f32)) Uniforms {
    const position = blockPosition(camera, overlay.cell);
    const transform = clipFromPosition(camera, position);
    const eye = chunks.getLocalPosition(camera.position) - position;
    return .{
        .clip_from_block = transform,
        .block_from_clip = zmath.inverse(transform),
        .stroke = .{ viewport[0], viewport[1], width_pixels, 63 },
        .color = overlay.color,
        .parameters = if (overlay.occupied) .{ 1, @floatFromInt(faceMask(eye)), 0, 0 } else @splat(0),
    };
}

pub fn createPipeline(gctx: *zgpu.GraphicsContext, layouts: *const BindGroupLayouts, format: wgpu.TextureFormat) Pipeline {
    return createDepthPipeline(gctx, layouts, format, .less_equal);
}

pub fn createOccludedPipeline(gctx: *zgpu.GraphicsContext, layouts: *const BindGroupLayouts, format: wgpu.TextureFormat) Pipeline {
    return createDepthPipeline(gctx, layouts, format, .greater);
}

fn createDepthPipeline(gctx: *zgpu.GraphicsContext, layouts: *const BindGroupLayouts, format: wgpu.TextureFormat, compare: wgpu.CompareFunction) Pipeline {
    const layout = gctx.createPipelineLayout(&.{layouts.block_outline.bind_group_layout_handle});
    defer gctx.releaseResource(layout);
    const module = zgpu.createWgslShaderModule(gctx.device, shader, "block_outline");
    defer module.release();
    const targets = [_]wgpu.ColorTargetState{.{ .format = format, .blend = &.{
        .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
        .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
    } }};
    const handle = gctx.createRenderPipeline(layout, .{
        .label = "block_outline",
        .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        .depth_stencil = &.{
            .format = .depth32_float,
            .depth_write_enabled = false,
            .depth_compare = compare,
            // Fragment depth follows the target surface under the expanded stroke.
        },
        .vertex = .{ .module = module, .entry_point = "vs" },
        .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len },
    });
    return Pipeline.init(gctx, handle);
}

test "block outline rebases chunk boundaries and periodic camera positions" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 } });
    const block: [3]u32 = .{ 0, 4096, 128 };
    var camera = Camera.init(&layout, 1);
    camera.updatePosition(.{ -8192.5, 0.5, 0.5 });
    const expected = clipFromBlock(&camera, block);
    try std.testing.expectEqual(@as(f32, 1), uniforms(&camera, block, .{ 128, 128 }).stroke[3]);
    if (comptime WorldLayout.wrap_x) {
        for ([_]f64{ 16384, -32768, 16384 * 10000000000.0 }) |trip| {
            camera.updatePosition(.{ -8192.5 + trip, 0.5, 0.5 });
            const actual = clipFromBlock(&camera, block);
            try std.testing.expectEqual(@as(f32, 1), uniforms(&camera, block, .{ 128, 128 }).stroke[3]);
            inline for (0..4) |column| inline for (0..4) |row| {
                try std.testing.expectApproxEqAbs(expected[column][row], actual[column][row], 0.000001);
            };
        }
    }
    const center = utils.matApply(expected, .{ 0.5, 0.5, 0.5, 1 });
    // Across the seam, the block center is one metre to the camera's right.
    try std.testing.expectApproxEqAbs(camera.clip_from_view[0][0], center[0], 0.000001);
}

test "cell overlays retain signed finite edges and rebase across the wrapped seam" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 2, 2 } });
    var camera = Camera.init(&layout, 1);
    camera.updatePosition(.{ -64.5, -31.5, -31.5 });
    const outside = overlayUniforms(&camera, .{ .cell = .{ 0, 0, -1 }, .color = .{ 1, 0, 0, 0.5 } }, .{ 128, 128 });
    try std.testing.expectEqualDeep(@Vector(3, f32){ 32, 0, -1 }, blockPosition(&camera, .{ 0, 0, -1 }));
    try std.testing.expectEqualDeep(zmath.Vec{ 1, 0, 0, 0.5 }, outside.color);
    try std.testing.expectEqual(@as(f32, 63), outside.stroke[3]);
    try std.testing.expectEqual(@as(f32, 0), outside.parameters[0]);
    const solid = overlayUniforms(&camera, .{ .cell = .{ 0, 0, 0 }, .color = .{ 1, 0.65, 0.1, 0.65 }, .occupied = true }, .{ 128, 128 });
    try std.testing.expectEqual(@as(f32, 63), solid.stroke[3]);
    try std.testing.expectEqual(@as(f32, 1), solid.parameters[0]);
    try std.testing.expectEqual(@as(f32, 1), solid.parameters[1]);
    if (comptime WorldLayout.wrap_x) {
        const a = blockPosition(&camera, .{ -1, 0, 0 });
        const b = blockPosition(&camera, .{ 127, 0, 0 });
        try std.testing.expectEqualDeep(a, b);
    }
}
