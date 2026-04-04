const std = @import("std");

const zmath = @import("zmath");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const BufferType = enum(u8) {
    index,
    vertex,
};

pub const BufferDescriptor = struct {
    type: BufferType,
    index_format: wgpu.IndexFormat,
    handle: zgpu.BufferHandle,
    gpu_buffer: wgpu.Buffer,
    elements_count: u32,
    buffer_size: u64,

    pub fn applyVertexBuffer(
        descriptor: *const BufferDescriptor,
        pass: wgpu.RenderPassEncoder,
        slot: u32,
    ) void {
        pass.setVertexBuffer(
            slot,
            descriptor.gpu_buffer,
            0,
            descriptor.buffer_size,
        );
    }

    pub fn applyIndexBuffer(
        descriptor: *const BufferDescriptor,
        pass: wgpu.RenderPassEncoder,
    ) void {
        pass.setIndexBuffer(
            descriptor.gpu_buffer,
            descriptor.index_format,
            0,
            descriptor.buffer_size,
        );
    }
};

pub const TextureDescriptor = struct {
    texture_handle: zgpu.TextureHandle,
    texture: wgpu.Texture,
    view_handle: zgpu.TextureViewHandle,
    view: wgpu.TextureView,

    pub fn applyTexture(
        descriptor: *const TextureDescriptor,
        pass: wgpu.RenderPassEncoder,
    ) void {
        _ = descriptor;
        _ = pass;
    }

    pub fn generateMipmaps(
        descriptor: *const TextureDescriptor,
        gctx: *zgpu.GraphicsContext,
        allocator: std.mem.Allocator,
    ) !void {
        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            gctx.generateMipmaps(allocator, encoder, descriptor.texture_handle);

            break :commands encoder.finish(null);
        };
        defer commands.release();
        gctx.submit(&.{commands});
    }
};

const F32x3 = @Vector(3, f32);

pub const GeometryBounds = struct {
    min: F32x3,
    max: F32x3,
    offset: zmath.Vec,
    radius: f32,
    // TODO: @deprecated, not sure where it can be actually used.
    origin_radius: f32,

    pub fn getCenter(self: GeometryBounds) F32x3 {
        return (self.min + self.max) * @as(F32x3, @splat(0.5));
    }
};
