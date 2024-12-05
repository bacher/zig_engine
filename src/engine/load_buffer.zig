const std = @import("std");

const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const gltf_loader = @import("gltf_loader");

const types = @import("./types.zig");
const BufferDescriptor = types.BufferDescriptor;
const BufferType = types.BufferType;

pub fn loadBufferIntoGpu(
    comptime T: type,
    gctx: *zgpu.GraphicsContext,
    comptime buffer_type: BufferType,
    buffer_data: gltf_loader.ModelBuffer(T),
) !BufferDescriptor {
    const index_format: wgpu.IndexFormat = comptime result: {
        const ElementType = std.meta.Elem(T);

        if (buffer_type == .index) {
            switch (ElementType) {
                u16 => break :result wgpu.IndexFormat.uint16,
                u32 => break :result wgpu.IndexFormat.uint32,
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
        .size = buffer_data.buffer.len,
    });

    if (gctx.lookupResource(handle)) |gpu_buffer| {
        gctx.queue.writeBuffer(gpu_buffer, 0, u8, buffer_data.buffer);

        return .{
            .type = buffer_type,
            .index_format = index_format,
            .handle = handle,
            .gpu_buffer = gpu_buffer,
            .elements_count = @intCast(buffer_data.data.len),
            .buffer_size = @sizeOf(T) * buffer_data.data.len,
        };
    } else {
        return error.BufferIsNotReady;
    }
}
