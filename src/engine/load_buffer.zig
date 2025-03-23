const std = @import("std");

const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const gltf_loader = @import("gltf_loader");

const types = @import("./types.zig");
const BufferDescriptor = types.BufferDescriptor;
const BufferType = types.BufferType;

pub fn loadBufferIntoGpu(
    gctx: *zgpu.GraphicsContext,
    comptime buffer_type: BufferType,
    model_buffer: gltf_loader.ModelBuffer,
) !BufferDescriptor {
    const index_format: wgpu.IndexFormat = result: {
        if (buffer_type == .index) {
            switch (model_buffer.type) {
                .u16 => break :result wgpu.IndexFormat.uint16,
                .u32 => break :result wgpu.IndexFormat.uint32,
                else => return error.InvalidIndexFormat,
            }
        } else {
            break :result wgpu.IndexFormat.undef;
        }
    };

    const handle = gctx.createBuffer(.{
        .usage = .{
            .copy_dst = true,
            .vertex = buffer_type == BufferType.vertex,
            .index = buffer_type == BufferType.index,
        },
        .size = model_buffer.buffer.len,
    });

    if (gctx.lookupResource(handle)) |gpu_buffer| {
        gctx.queue.writeBuffer(gpu_buffer, 0, u8, model_buffer.buffer);

        return .{
            .type = buffer_type,
            .index_format = index_format,
            .handle = handle,
            .gpu_buffer = gpu_buffer,
            .elements_count = model_buffer.elements_count,
            .buffer_size = model_buffer.byte_length,
        };
    } else {
        return error.BufferIsNotReady;
    }
}
