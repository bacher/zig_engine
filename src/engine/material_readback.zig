//! Execute production material appearance code against a transparent atlas sample.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const voxel = @import("voxel/voxel_chunk.zig");
const readback = @import("world_coordinate_readback.zig");

const compute =
    \\struct MaterialResult { color: vec4f, uv: vec2f, padding: vec2f, }
    \\@group(0) @binding(0) var<storage, read_write> results: array<MaterialResult>;
    \\@compute @workgroup_size(1)
    \\fn main(@builtin(global_invocation_id) id: vec3u) {
    \\    let material = id.x / 6u;
    \\    let side = id.x % 6u;
    \\    results[id.x] = MaterialResult(materialColor(vec2u(material, side), vec4f(0.2, 0.4, 0.6, 0.0)), getUv(side, 2u, material), vec2f(0.0));
    \\}
;
const Result = extern struct { color: [4]f32, uv: [2]f32, padding: [2]f32 };

pub fn check(device: wgpu.Device, mapping: *readback.MapResponse) !void {
    const count: usize = (@intFromEnum(voxel.RenderMaterial.grass_frozen) + 1) * 6;
    const bytes = count * @sizeOf(Result);
    const source = @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/material_color.wgsl") ++ compute;
    const shader = zgpu.createWgslShaderModule(device, source, "material_readback");
    defer shader.release();
    const pipeline = device.createComputePipeline(.{ .compute = .{ .module = shader, .entry_point = "main" } });
    defer pipeline.release();
    const layout = pipeline.getBindGroupLayout(0);
    defer layout.release();
    const output = device.createBuffer(.{ .size = bytes, .usage = .{ .storage = true, .copy_src = true } });
    defer output.release();
    const mapped = device.createBuffer(.{ .size = bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer mapped.release();
    const entries = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = output, .size = bytes }};
    const bindings = device.createBindGroup(.{ .layout = layout, .entry_count = entries.len, .entries = &entries });
    defer bindings.release();
    const queue = device.getQueue();
    defer queue.release();
    const encoder = device.createCommandEncoder(null);
    defer encoder.release();
    const pass = encoder.beginComputePass(null);
    defer pass.release();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindings, null);
    pass.dispatchWorkgroups(count, 1, 1);
    pass.end();
    encoder.copyBufferToBuffer(output, 0, mapped, 0, bytes);
    const commands = encoder.finish(null);
    defer commands.release();
    queue.submit(&.{commands});
    mapping.* = .{};
    mapped.mapAsync(.{ .read = true }, 0, bytes, readback.MapResponse.callback, mapping);
    defer mapped.unmap();
    try readback.waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    const results = mapped.getConstMappedRange(Result, 0, count) orelse return error.NoMappedGpuResults;
    for (results, 0..) |result, i| {
        const material = i / 6;
        const side = i % 6;
        if (material == @intFromEnum(voxel.RenderMaterial.water)) {
            try std.testing.expectEqual(@as(f32, 1), result.color[3]);
            try std.testing.expect(result.color[2] > result.color[1] and result.color[1] > result.color[0]);
        } else if (material == @intFromEnum(voxel.RenderMaterial.leaves)) {
            try std.testing.expectEqual(@as(f32, 1), result.color[3]);
            try std.testing.expect(result.color[1] > result.color[0] and result.color[1] > result.color[2]);
        } else if (material >= @intFromEnum(voxel.RenderMaterial.metal_ore) and material <= @intFromEnum(voxel.RenderMaterial.deeprock)) {
            try std.testing.expectEqual(@as(f32, 1), result.color[3]);
        } else {
            try std.testing.expectEqual(@as(f32, 0), result.color[3]);
        }
        if (material == @intFromEnum(voxel.RenderMaterial.grass_steppe) and side == 5) {
            try std.testing.expect(result.color[0] > result.color[1] and result.color[1] > result.color[2]);
        }
        if (material == @intFromEnum(voxel.RenderMaterial.grass_frozen)) {
            const expected: [2]f32 = if (side == 5) .{ 0, 4 * 0.046875 } else .{ 2 * 0.046875, 0 };
            try std.testing.expectEqualSlices(f32, &expected, &result.uv);
        }
    }
}
