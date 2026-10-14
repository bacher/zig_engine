//! Execute production custom geometry on Dawn and compare it with CPU collision planes.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const custom = @import("voxel/custom_block.zig");
const coordinate_readback = @import("world_coordinate_readback.zig");
const WorldLayout = @import("world_layout.zig").WorldLayout;

const compute_body =
    \\const origin_chunk = vec3i(0, 0, 0);
    \\struct Result { position: vec4f, normal: vec4f, uv: vec4f, }
    \\@group(0) @binding(0) var<storage, read> custom_blocks: array<GPU_CustomBlock>;
    \\@group(0) @binding(1) var<storage, read_write> results: array<Result>;
    \\@compute @workgroup_size(1)
    \\fn main(@builtin(global_invocation_id) id: vec3u) {
    \\    let vertex = customVertex(id.x / 36u, id.x % 36u);
    \\    results[id.x] = Result(vertex.position, vec4f(vertex.normal, 0.0), vec4f(vertex.uv, 1.0, 0.0));
    \\}
;
const Result = extern struct { position: [4]f32, normal: [4]f32, uv: [4]f32 };

pub fn check(device: wgpu.Device, layout: *const WorldLayout, mapping: *coordinate_readback.MapResponse) !void {
    var inputs: [5]custom.GPU_CustomBlock = undefined;
    for (&inputs, 0..) |*input, i| input.* = .{
        .chunk_origin = .{ layout.size_in_chunks[0] - 1, 0, 0 },
        .direction = @intCast(i % 4),
        .local_origin = .{ 2, 3, 4 },
        .adaptive = @intFromBool(i == 4),
        .high = 0.75,
        .low = 0.5,
    };
    const source = try layout.shaderSource(std.testing.allocator, @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/custom_geometry.wgsl") ++ compute_body);
    defer std.testing.allocator.free(source);
    const shader = zgpu.createWgslShaderModule(device, source.ptr, "custom_geometry_readback");
    defer shader.release();
    const pipeline = device.createComputePipeline(.{ .compute = .{ .module = shader, .entry_point = "main" } });
    defer pipeline.release();
    const bind_layout = pipeline.getBindGroupLayout(0);
    defer bind_layout.release();
    const input_buffer = device.createBuffer(.{ .size = @sizeOf(@TypeOf(inputs)), .usage = .{ .storage = true, .copy_dst = true } });
    defer input_buffer.release();
    const count = inputs.len * 36;
    const bytes = count * @sizeOf(Result);
    const output = device.createBuffer(.{ .size = bytes, .usage = .{ .storage = true, .copy_src = true } });
    defer output.release();
    const readback = device.createBuffer(.{ .size = bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.release();
    const entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .buffer = input_buffer, .size = @sizeOf(@TypeOf(inputs)) }, .{ .binding = 1, .buffer = output, .size = bytes } };
    const bindings = device.createBindGroup(.{ .layout = bind_layout, .entry_count = entries.len, .entries = &entries });
    defer bindings.release();
    const queue = device.getQueue();
    defer queue.release();
    queue.writeBuffer(input_buffer, 0, custom.GPU_CustomBlock, &inputs);
    const encoder = device.createCommandEncoder(null);
    defer encoder.release();
    const pass = encoder.beginComputePass(null);
    defer pass.release();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindings, null);
    pass.dispatchWorkgroups(count, 1, 1);
    pass.end();
    encoder.copyBufferToBuffer(output, 0, readback, 0, bytes);
    const commands = encoder.finish(null);
    defer commands.release();
    queue.submit(&.{commands});
    mapping.* = .{};
    readback.mapAsync(.{ .read = true }, 0, bytes, coordinate_readback.MapResponse.callback, mapping);
    defer readback.unmap();
    try coordinate_readback.waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    const results = readback.getConstMappedRange(Result, 0, count) orelse return error.NoMappedGpuResults;
    const chunk_delta = layout.getChunkDelta(inputs[0].chunk_origin, .{ 0, 0, 0 });
    const base_x: f32 = @as(f32, @floatFromInt(chunk_delta[0])) * 32 + 2;
    for (results, 0..) |result, i| {
        const block = i / 36;
        const side = (i % 36) / 6;
        const x = result.position[0] - base_x;
        const y = result.position[1] - 3;
        const z = result.position[2] - 4;
        try std.testing.expectEqual(@as(f32, 1), result.position[3]);
        try std.testing.expectEqual(@as(f32, 1), result.uv[2]);
        const normal: @Vector(3, f32) = .{ result.normal[0], result.normal[1], result.normal[2] };
        try std.testing.expectApproxEqAbs(@as(f32, 1), @reduce(.Add, normal * normal), 1e-6);
        if (block == 4) {
            try std.testing.expect(x >= 0.119 and x <= 0.881 and y >= 0.119 and y <= 0.881 and z >= 0.099 and z <= 0.901);
        } else {
            const shape: custom.Shape = .{ .slope = .{ .downhill = @enumFromInt(block), .high = 0.75, .low = 0.5 } };
            try std.testing.expect(x >= 0 and x <= 1 and y >= 0 and y <= 1);
            try std.testing.expectApproxEqAbs(if (z == 0) @as(f64, 0) else shape.height(x, y), @as(f64, z), 1e-6);
            if (side == 5) {
                const gradient = shape.gradient();
                try std.testing.expectApproxEqAbs(-gradient[0], @as(f64, result.normal[0] / result.normal[2]), 1e-6);
                try std.testing.expectApproxEqAbs(-gradient[1], @as(f64, result.normal[1] / result.normal[2]), 1e-6);
            }
        }
    }
}
