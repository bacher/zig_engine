const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const BufferDescriptor = @import("./types.zig").BufferDescriptor;

pub const BufferType = enum(u8) {
    index,
    vertex,
};

pub fn loadBufferIntoGpu(comptime T: type, gctx: *zgpu.GraphicsContext, buffer_type: BufferType, data: []T) !BufferDescriptor {
    const handle = gctx.createBuffer(.{
        .usage = .{
            .copy_dst = true,
            .vertex = buffer_type == BufferType.vertex,
            .index = buffer_type == BufferType.index,
        },
        .size = @sizeOf(T) * data.len,
    });

    if (gctx.lookupResource(handle)) |buffer| {
        gctx.queue.writeBuffer(buffer, 0, T, data);

        return .{
            .handle = handle,
            .buffer = buffer,
        };
    } else {
        return error.BufferIsNotReady;
    }
}
