const std = @import("std");

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
