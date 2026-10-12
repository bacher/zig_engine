const zgpu = @import("zgpu");
const zmath = @import("zmath");
const BindGroup = @import("../bind_group.zig").BindGroup;

/// Keep the field order in sync with shaders/block_outline.wgsl.
pub const Instance = extern struct {
    clip_from_block: zmath.Mat,
    block_from_clip: zmath.Mat,
    /// Viewport xy, stroke width, and a bit mask of camera-facing cube faces.
    stroke: zmath.Vec,
    color: zmath.Vec = .{ 0, 1, 0, 1 },
    /// x: surface depth correction; y: eligible face mask; zw: reserved.
    parameters: zmath.Vec = .{ 1, 63, 0, 0 },
};

/// 64 application overlays plus an optional ordinary focused cell.
pub const instance_capacity = 65;
pub const instance_buffer_size = instance_capacity * @sizeOf(Instance);

pub const BlockOutlineBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,
    instance_buffer_handle: zgpu.BufferHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) BlockOutlineBindGroupLayout {
        return .{
            .bind_group_layout_handle = gctx.createBindGroupLayout(&.{
                zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .read_only_storage, true, @sizeOf(Instance)),
            }),
            .instance_buffer_handle = gctx.createBuffer(.{
                .label = "block outline instances",
                .usage = .{ .storage = true, .copy_dst = true },
                .size = instance_buffer_size,
            }),
        };
    }

    pub fn deinit(self: BlockOutlineBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.bind_group_layout_handle);
        gctx.releaseResource(self.instance_buffer_handle);
    }

    pub fn createBindGroup(self: BlockOutlineBindGroupLayout, gctx: *zgpu.GraphicsContext) BindGroup {
        const handle = gctx.createBindGroup(self.bind_group_layout_handle, &.{
            .{ .binding = 0, .buffer_handle = self.instance_buffer_handle, .offset = 0, .size = instance_buffer_size },
        });
        return .{ .bind_group_handle = handle, .wgpu_bind_group = gctx.lookupResource(handle).? };
    }
};
