//! Execute production custom geometry on Dawn; check slopes and tileable visual bumps.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const custom = @import("voxel/custom_block.zig");
const coordinate_readback = @import("world_coordinate_readback.zig");
const WorldLayout = @import("world_layout.zig").WorldLayout;

const compute_body =
    \\const origin_chunk = vec3i(0, 0, 0);
    \\struct GPU_VertexReadback { position: vec4f, normal: vec4f, uv: vec4f, }
    \\@group(0) @binding(0) var<storage, read> custom_blocks: array<GPU_CustomBlock>;
    \\@group(0) @binding(1) var<storage, read_write> results: array<GPU_VertexReadback>;
    \\@compute @workgroup_size(1)
    \\fn main(@builtin(global_invocation_id) id: vec3u) {
    \\    let block = id.x / ADAPTIVE_VERTEX_COUNT;
    \\    let index = id.x % ADAPTIVE_VERTEX_COUNT;
    \\    if (custom_blocks[block].adaptive == 0u && index >= 36u) { return; }
    \\    let vertex = customVertex(block, index);
    \\    results[id.x] = GPU_VertexReadback(vertex.position, vec4f(vertex.normal, 0.0), vec4f(vertex.uv, 0.0, 0.0));
    \\    if (custom_blocks[block].adaptive != 0u) {
    \\        let preview = blockVertex(index, 14u);
    \\        let custom_preview = blockVertex(index, 255u);
    \\        let position = chunkOffset(custom_blocks[block].chunk_origin, origin_chunk) + custom_blocks[block].local_origin + preview.position.xyz;
    \\        results[id.x].normal.w = select(0.0, 1.0, all(position == vertex.position.xyz) && all(preview.position == custom_preview.position));
    \\        results[id.x].uv.w = select(0.0, 1.0, all(preview.normal == vertex.normal) && all(preview.uv == vertex.uv) && all(preview.normal == custom_preview.normal) && all(preview.uv == custom_preview.uv));
    \\    }
    \\}
;
const GPU_VertexReadback = extern struct { position: [4]f32, normal: [4]f32, uv: [4]f32 };

pub fn check(device: wgpu.Device, layout: *const WorldLayout, mapping: *coordinate_readback.MapResponse) !void {
    // Include every first/interior/final section, including the zero-height end.
    const lengths = [_]u32{ 4, 7, 12 };
    const slope_count = 4 * (4 + 7 + 12);
    var inputs: [slope_count + 4]custom.GPU_CustomBlock = undefined;
    var next: usize = 0;
    for (std.enums.values(custom.Direction)) |direction| for (lengths) |length| {
        for (0..length) |section| {
            const n: f32 = @floatFromInt(length);
            inputs[next] = .{
                .chunk_origin = .{ layout.size_in_chunks[0] - 1, 0, 0 },
                .direction = @intFromEnum(direction),
                .local_origin = .{ 2, 3, 4 },
                .adaptive = 0,
                .high = 1 - @as(f32, @floatFromInt(section)) / n,
                .low = 1 - @as(f32, @floatFromInt(section + 1)) / n,
            };
            next += 1;
        }
    };
    // A 2x2 patch crossing both chunk boundaries, including the wrapped x seam.
    for (0..4) |i| inputs[next + i] = .{
        .chunk_origin = .{ if (i % 2 == 0) (if (WorldLayout.wrap_x) layout.size_in_chunks[0] - 1 else 0) else (if (WorldLayout.wrap_x) 0 else 1), @intCast(i / 2), 0 },
        .direction = 0,
        .local_origin = .{ if (i % 2 == 0) 31 else 0, if (i / 2 == 0) 31 else 0, 4 },
        .adaptive = 1,
        .high = 1,
        .low = 1,
    };
    const source = try layout.shaderSource(std.testing.allocator, @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/adaptive_geometry.wgsl") ++ @embedFile("shaders/voxel/custom_geometry.wgsl") ++ compute_body);
    defer std.testing.allocator.free(source);
    const shader = zgpu.createWgslShaderModule(device, source.ptr, "custom_geometry_readback");
    defer shader.release();
    const pipeline = device.createComputePipeline(.{ .compute = .{ .module = shader, .entry_point = "main" } });
    defer pipeline.release();
    const bind_layout = pipeline.getBindGroupLayout(0);
    defer bind_layout.release();
    const input_buffer = device.createBuffer(.{ .size = @sizeOf(@TypeOf(inputs)), .usage = .{ .storage = true, .copy_dst = true } });
    defer input_buffer.release();
    const stride = custom.adaptive_vertex_count;
    const count = inputs.len * stride;
    const bytes = count * @sizeOf(GPU_VertexReadback);
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
    const results = readback.getConstMappedRange(GPU_VertexReadback, 0, count) orelse return error.NoMappedGpuResults;
    for (results, 0..) |result, i| {
        const block = i / stride;
        const index = i % stride;
        const adaptive = inputs[block].adaptive == 1;
        if (!adaptive and index >= custom.slope_vertex_count) continue;
        const side = if (!adaptive) index / 6 else if (index < 96) 5 else if (index < 192) (index - 96) / 24 else 4;
        const chunk_delta = layout.getChunkDelta(inputs[block].chunk_origin, .{ 0, 0, 0 });
        const x = result.position[0] - @as(f32, @floatFromInt(chunk_delta[0])) * 32 - inputs[block].local_origin[0];
        const y = result.position[1] - @as(f32, @floatFromInt(chunk_delta[1])) * 32 - inputs[block].local_origin[1];
        const z = result.position[2] - 4;
        try std.testing.expectEqual(@as(f32, 1), result.position[3]);
        const uv_corners = [_][2]f32{ .{ 0, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
        const normal: @Vector(3, f32) = .{ result.normal[0], result.normal[1], result.normal[2] };
        try std.testing.expectApproxEqAbs(@as(f32, 1), @reduce(.Add, normal * normal), 1e-6);
        if (adaptive) {
            // Held previews use exactly the placed block's local mesh and atlas UVs.
            try std.testing.expectEqual(@as(f32, 1), result.normal[3]);
            try std.testing.expectEqual(@as(f32, 1), result.uv[3]);
            try std.testing.expect(x >= 0 and x <= 1 and y >= 0 and y <= 1);
            try std.testing.expect(z == 0 or (z >= 0.6875 and z <= 0.8125));
            if (side == 5) {
                try std.testing.expect(z >= 0.6875 and z <= 0.8125);
                try std.testing.expectApproxEqAbs((4 + x) * 0.046875, result.uv[0], 1e-6);
                try std.testing.expectApproxEqAbs((1 - y) * 0.046875, result.uv[1], 1e-6);
            } else if (side == 4) {
                try std.testing.expectEqual(@as(f32, 0), z);
            } else {
                try std.testing.expect(if (side < 2) x == @as(f32, @floatFromInt(side)) else y == @as(f32, @floatFromInt(side - 2)));
                const along = if (side < 2) y else x;
                const u = if (side == 0 or side == 3) along else 1 - along;
                try std.testing.expectApproxEqAbs((4 + u) * 0.046875, result.uv[0], 1e-6);
                try std.testing.expectApproxEqAbs((1 - z / 0.8125) * 0.046875, result.uv[1], 1e-6);
            }
            // Verify winding and normals from the actual GPU triangle positions.
            const triangle = i - index % 3;
            const a: @Vector(3, f32) = results[triangle].position[0..3].*;
            const b: @Vector(3, f32) = results[triangle + 1].position[0..3].*;
            const c: @Vector(3, f32) = results[triangle + 2].position[0..3].*;
            const ab = b - a;
            const ac = c - a;
            const cross: @Vector(3, f32) = .{ ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0] };
            try std.testing.expectApproxEqAbs(@as(f32, 1), @reduce(.Add, cross * normal) / @sqrt(@reduce(.Add, cross * cross)), 1e-6);
        } else {
            for (0..2) |axis| try std.testing.expectEqual((@as(f32, if (axis == 0) 0 else 1) + uv_corners[index % 6][axis]) * 0.046875, result.uv[axis]);
            const shape: custom.Shape = .{ .slope = .{ .downhill = @enumFromInt(inputs[block].direction), .high = inputs[block].high, .low = inputs[block].low } };
            try std.testing.expect(x >= 0 and x <= 1 and y >= 0 and y <= 1);
            try std.testing.expectApproxEqAbs(if (z == 0) @as(f64, 0) else shape.height(x, y), @as(f64, z), 1e-6);
            if (side == 5) {
                const gradient = shape.gradient();
                try std.testing.expectApproxEqAbs(-gradient[0], @as(f64, result.normal[0] / result.normal[2]), 1e-6);
                try std.testing.expectApproxEqAbs(-gradient[1], @as(f64, result.normal[1] / result.normal[2]), 1e-6);
            }
        }
    }
    for (slope_count..inputs.len) |block| {
        var min: @Vector(3, f32) = @splat(std.math.inf(f32));
        var max: @Vector(3, f32) = @splat(-std.math.inf(f32));
        const delta = layout.getChunkDelta(inputs[block].chunk_origin, .{ 0, 0, 0 });
        const base: @Vector(3, f32) = @as(@Vector(3, f32), @floatFromInt(delta)) * @as(@Vector(3, f32), @splat(32)) + @as(@Vector(3, f32), inputs[block].local_origin);
        for (results[block * stride ..][0..stride]) |vertex| {
            const local = @as(@Vector(3, f32), vertex.position[0..3].*) - base;
            min = @min(min, local);
            max = @max(max, local);
        }
        try std.testing.expectEqual(@Vector(3, f32){ 0, 0, 0 }, min);
        try std.testing.expectEqual(@Vector(3, f32){ 1, 1, 0.8125 }, max);
    }
    // Matching world-space top vertices on every shared edge, even across chunks.
    inline for ([_][3]usize{ .{ 0, 1, 0 }, .{ 2, 3, 0 }, .{ 0, 2, 1 }, .{ 1, 3, 1 } }) |pair| {
        const left = (slope_count + pair[0]) * stride;
        const right = (slope_count + pair[1]) * stride;
        const axis = pair[2];
        const delta = layout.getChunkDelta(inputs[slope_count + pair[0]].chunk_origin, .{ 0, 0, 0 });
        const edge = @as(f32, @floatFromInt(delta[axis])) * 32 + inputs[slope_count + pair[0]].local_origin[axis] + 1;
        var matched: usize = 0;
        for (results[left..][0..96]) |vertex| {
            if (vertex.position[axis] != edge) continue;
            var found = false;
            for (results[right..][0..96]) |neighbor| {
                if (std.meta.eql(vertex.position, neighbor.position)) found = true;
            }
            try std.testing.expect(found);
            matched += 1;
        }
        try std.testing.expect(matched >= 5);
    }
}
