const zgpu = @import("zgpu");
const zmath = @import("zmath");
const BindGroup = @import("../bind_group.zig").BindGroup;

/// Keep the field order in sync with shaders/block_outline.wgsl.
pub const Uniforms = extern struct {
    clip_from_block: zmath.Mat,
    block_from_clip: zmath.Mat,
    /// Viewport xy, stroke width, and a bit mask of camera-facing cube faces.
    stroke: zmath.Vec,
};

pub const BlockOutlineBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) BlockOutlineBindGroupLayout {
        return .{ .bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, @sizeOf(Uniforms)),
        }) };
    }

    pub fn deinit(self: BlockOutlineBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.bind_group_layout_handle);
    }

    pub fn createBindGroup(self: BlockOutlineBindGroupLayout, gctx: *zgpu.GraphicsContext) BindGroup {
        const handle = gctx.createBindGroup(self.bind_group_layout_handle, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(Uniforms) },
        });
        return .{ .bind_group_handle = handle, .wgpu_bind_group = gctx.lookupResource(handle).? };
    }
};
