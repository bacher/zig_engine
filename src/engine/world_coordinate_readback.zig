//! Test-only execution/readback of the production WGSL coordinate helper.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const ChunkCoords = @import("world_math.zig").ChunkCoords;
const CHUNK_SIZE = @import("chunk_utils.zig").CHUNK_SIZE;

const compute_body =
    \\struct Input {
    \\    chunk: vec4i,
    \\    origin: vec4i,
    \\}
    \\@group(0) @binding(0) var<storage, read> inputs: array<Input>;
    \\@group(0) @binding(1) var<storage, read_write> outputs: array<vec4f>;
    \\@compute @workgroup_size(1)
    \\fn main(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&inputs)) { return; }
    \\    let input = inputs[id.x];
    \\    outputs[id.x] = vec4f(chunkOffset(input.chunk.xyz, input.origin.xyz), 1.0);
    \\}
;

// vec4 storage fields avoid vec3's padded array stride; the last output lane
// marks each invocation as written, including cases with zero xyz offsets.
const Input = extern struct { chunk: [4]i32, origin: [4]i32 };
const Output = [4]f32;

const Case = struct {
    name: []const u8,
    chunk: ChunkCoords,
    origin: ChunkCoords,
};

pub const MapResponse = struct {
    done: bool = false,
    status: wgpu.BufferMapAsyncStatus = .unknown,

    fn callback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *MapResponse = @ptrCast(@alignCast(userdata));
        self.status = status;
        self.done = true;
    }
};

/// Pump Dawn's callbacks with a wall-clock deadline, rather than a machine-speed
/// dependent iteration count. Callers keep callback state alive through teardown.
pub fn waitForCallback(device: wgpu.Device, done: *const bool) !void {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    while (!done.*) {
        device.tick();
        if (done.*) break;
        if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >= 5 * std.time.ns_per_s) return error.GpuCallbackTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

pub fn check(device: wgpu.Device, layout: *const WorldLayout, mapping: *MapResponse) !void {
    const width = layout.size_in_chunks[0];
    const half = @divExact(width, 2);
    const high = std.math.maxInt(i32);
    const low = std.math.minInt(i32);
    const far = (1 << 24) + 3;
    const cases = [_]Case{
        .{ .name = "zero", .chunk = .{ 0, 0, 0 }, .origin = .{ 0, 0, 0 } },
        .{ .name = "x seam forward", .chunk = .{ 0, 7, -9 }, .origin = .{ width - 1, 7, -9 } },
        .{ .name = "x seam reverse", .chunk = .{ width - 1, 7, -9 }, .origin = .{ 0, 7, -9 } },
        .{ .name = "negative x seam", .chunk = .{ -1, 0, 0 }, .origin = .{ 0, 0, 0 } },
        .{ .name = "positive repeated x", .chunk = .{ 3 * width + 1, 0, 0 }, .origin = .{ 1, 0, 0 } },
        .{ .name = "negative repeated x", .chunk = .{ 1 - 3 * width, 0, 0 }, .origin = .{ 1, 0, 0 } },
        .{ .name = "positive half-period tie", .chunk = .{ half, 0, 0 }, .origin = .{ 0, 0, 0 } },
        .{ .name = "negative half-period tie", .chunk = .{ 0, 0, 0 }, .origin = .{ half, 0, 0 } },
        .{ .name = "above positive half-period", .chunk = .{ half + 1, 0, 0 }, .origin = .{ 0, 0, 0 } },
        .{ .name = "below negative half-period", .chunk = .{ 0, 0, 0 }, .origin = .{ half + 1, 0, 0 } },
        .{ .name = "below positive half-period", .chunk = .{ half - 1, 0, 0 }, .origin = .{ 0, 0, 0 } },
        .{ .name = "above negative half-period", .chunk = .{ 0, 0, 0 }, .origin = .{ half - 1, 0, 0 } },
        .{ .name = "positive far adjacent", .chunk = .{ far, far, far }, .origin = .{ far - 1, far - 1, far - 1 } },
        .{ .name = "positive far adjacent reverse", .chunk = .{ far - 1, far - 1, far - 1 }, .origin = .{ far, far, far } },
        .{ .name = "negative far adjacent", .chunk = .{ -far, -far, -far }, .origin = .{ -far - 1, -far - 1, -far - 1 } },
        .{ .name = "negative far adjacent reverse", .chunk = .{ -far - 1, -far - 1, -far - 1 }, .origin = .{ -far, -far, -far } },
        .{ .name = "adjacent i32 maximum", .chunk = .{ high, high, high }, .origin = .{ high - 1, high - 1, high - 1 } },
        .{ .name = "adjacent i32 maximum reverse", .chunk = .{ high - 1, high - 1, high - 1 }, .origin = .{ high, high, high } },
        .{ .name = "adjacent i32 minimum", .chunk = .{ low + 1, low + 1, low + 1 }, .origin = .{ low, low, low } },
        .{ .name = "adjacent i32 minimum reverse", .chunk = .{ low, low, low }, .origin = .{ low + 1, low + 1, low + 1 } },
        .{ .name = "full signed range", .chunk = .{ high, high, low }, .origin = .{ low, low, high } },
        .{ .name = "full signed range reverse", .chunk = .{ low, low, high }, .origin = .{ high, high, low } },
        .{ .name = "signed limits to zero", .chunk = .{ high, low, 0 }, .origin = .{ 0, 0, low } },
        .{ .name = "signed limits to zero reverse", .chunk = .{ 0, 0, low }, .origin = .{ high, low, 0 } },
        .{ .name = "f32 conversion rounding", .chunk = .{ far - 2, -far + 2, far }, .origin = .{ 0, 0, 0 } },
        .{ .name = "f32 conversion rounding reverse", .chunk = .{ 0, 0, 0 }, .origin = .{ far - 2, -far + 2, far } },
    };
    var inputs: [cases.len]Input = undefined;
    for (cases, &inputs) |case, *input| {
        input.* = .{
            .chunk = .{ case.chunk[0], case.chunk[1], case.chunk[2], 0 },
            .origin = .{ case.origin[0], case.origin[1], case.origin[2], 0 },
        };
    }
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Input));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Input, "origin"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Output));

    const source = try layout.shaderSource(std.testing.allocator, compute_body);
    defer std.testing.allocator.free(source);
    const shader = zgpu.createWgslShaderModule(device, source.ptr, "coordinate_readback");
    defer shader.release();
    const pipeline = device.createComputePipeline(.{ .compute = .{ .module = shader, .entry_point = "main" } });
    defer pipeline.release();
    const bind_group_layout = pipeline.getBindGroupLayout(0);
    defer bind_group_layout.release();
    const input_buffer = device.createBuffer(.{ .label = "coordinate_inputs", .size = @sizeOf(@TypeOf(inputs)), .usage = .{ .storage = true, .copy_dst = true } });
    defer input_buffer.release();
    const result_size = cases.len * @sizeOf(Output);
    const output_buffer = device.createBuffer(.{ .label = "coordinate_outputs", .size = result_size, .usage = .{ .storage = true, .copy_src = true } });
    defer output_buffer.release();
    const readback_buffer = device.createBuffer(.{ .label = "coordinate_readback", .size = result_size, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback_buffer.release();
    const bindings = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = input_buffer, .size = @sizeOf(@TypeOf(inputs)) },
        .{ .binding = 1, .buffer = output_buffer, .size = result_size },
    };
    const bind_group = device.createBindGroup(.{ .layout = bind_group_layout, .entry_count = bindings.len, .entries = &bindings });
    defer bind_group.release();
    const queue = device.getQueue();
    defer queue.release();
    queue.writeBuffer(input_buffer, 0, Input, &inputs);
    const encoder = device.createCommandEncoder(null);
    defer encoder.release();
    const pass = encoder.beginComputePass(null);
    defer pass.release();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bind_group, null);
    pass.dispatchWorkgroups(cases.len, 1, 1);
    pass.end();
    encoder.copyBufferToBuffer(output_buffer, 0, readback_buffer, 0, result_size);
    const commands = encoder.finish(null);
    defer commands.release();
    queue.submit(&.{commands});

    mapping.* = .{};
    readback_buffer.mapAsync(.{ .read = true }, 0, result_size, MapResponse.callback, mapping);
    // Unmap also cancels a pending request on a timeout/error. The caller keeps
    // mapping alive until device destruction has completed any pending callbacks.
    defer readback_buffer.unmap();
    try waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    const results = readback_buffer.getConstMappedRange(Output, 0, cases.len) orelse return error.NoMappedGpuResults;
    for (cases, results) |case, result| {
        try std.testing.expectEqual(@as(f32, 1), result[3]);
        const delta = layout.getChunkDelta(case.chunk, case.origin);
        inline for (0..3) |axis| {
            const rounded: f32 = @floatFromInt(delta[axis]);
            const expected = rounded * @as(f32, CHUNK_SIZE);
            const actual = result[axis];
            // WGSL integer-to-float conversion may choose either neighboring
            // float for a nonrepresentable integer. Exactly representable cases
            // (especially +/-1 chunk at far coordinates) must match exactly.
            const exact = @as(i64, @intFromFloat(rounded)) == delta[axis];
            const expected_bits: u32 = @bitCast(expected);
            const actual_bits: u32 = @bitCast(actual);
            const ulps = @max(expected_bits, actual_bits) - @min(expected_bits, actual_bits);
            const matches = std.math.isFinite(actual) and (if (exact) expected == actual else ulps <= 1);
            if (!matches) {
                std.debug.print("GPU chunkOffset mismatch: wrap_x={}, width={d}, case={s}, axis={d}, chunk={d}, origin={d}, delta={d}, expected={d}, actual={d}, ULPs={d}\n", .{ WorldLayout.wrap_x, width, case.name, axis, case.chunk, case.origin, delta[axis], expected, actual, ulps });
                return error.GpuCoordinateMismatch;
            }
        }
    }
}
