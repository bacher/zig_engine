//! A single depth-tested block outline, independent of voxel face rendering.
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

/// Rebase storage coordinates to the camera chunk before narrowing to f32.
pub fn clipFromBlock(camera: *const Camera, block: [3]u32) zmath.Mat {
    var chunk: ChunkCoords = undefined;
    var local: @Vector(3, f32) = undefined;
    inline for (0..3) |axis| {
        chunk[axis] = @intCast(block[axis] / chunks.CHUNK_SIZE);
        local[axis] = @floatFromInt(block[axis] % chunks.CHUNK_SIZE);
    }
    const delta: @Vector(3, f32) = @floatFromInt(camera.layout.getChunkDelta(chunk, camera.chunk));
    const position = delta * @as(@Vector(3, f32), @splat(chunks.CHUNK_SIZE)) + local;
    return utils.matMul(camera.clip_from_world_chunked, zmath.translation(position[0], position[1], position[2]));
}

pub fn createPipeline(gctx: *zgpu.GraphicsContext, layouts: *const BindGroupLayouts, format: wgpu.TextureFormat) Pipeline {
    // Reuse the transform + vec4 uniform layout; the second uniform supplies
    // viewport dimensions and stroke width instead of the debug line color.
    const layout = gctx.createPipelineLayout(&.{layouts.lines.bind_group_layout_handle});
    defer gctx.releaseResource(layout);
    const module = zgpu.createWgslShaderModule(gctx.device, shader, "block_outline");
    defer module.release();
    const targets = [_]wgpu.ColorTargetState{.{ .format = format }};
    const handle = gctx.createRenderPipeline(layout, .{
        .label = "block_outline",
        .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        .depth_stencil = &.{
            .format = .depth32_float,
            .depth_write_enabled = false,
            .depth_compare = .less_equal,
            // Keep coplanar edge centers visible without changing scene depth.
            .depth_bias = -2,
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
    if (comptime WorldLayout.wrap_x) {
        for ([_]f64{ 16384, -32768, 16384 * 10000000000.0 }) |trip| {
            camera.updatePosition(.{ -8192.5 + trip, 0.5, 0.5 });
            const actual = clipFromBlock(&camera, block);
            inline for (0..4) |column| inline for (0..4) |row| {
                try std.testing.expectApproxEqAbs(expected[column][row], actual[column][row], 0.000001);
            };
        }
    }
    const center = utils.matApply(expected, .{ 0.5, 0.5, 0.5, 1 });
    // Across the seam, the block center is one metre to the camera's right.
    try std.testing.expectApproxEqAbs(camera.clip_from_view[0][0], center[0], 0.000001);
}
