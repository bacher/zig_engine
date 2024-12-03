const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const Vertex = struct {
    position: [3]f32,
    color: [3]f32,
};

pub const BufferDescriptor = struct {
    handle: zgpu.BufferHandle,
    buffer: wgpu.Buffer,
};
