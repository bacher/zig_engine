const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const ModelDescriptor = @import("./model_descriptor.zig").ModelDescriptor;
const WindowBoxDescriptor = @import("./window_box_descriptor.zig").WindowBoxDescriptor;
const BindGroupDescriptor = @import("./bind_group.zig").BindGroupDescriptor;

pub const Model = struct {
    model_descriptor: ModelDescriptor,
    bind_group_descriptor: BindGroupDescriptor,

    pub fn deinit(model: Model, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group_descriptor.deinit(gctx);
    }
};

pub const WindowBoxModel = struct {
    model_descriptor: WindowBoxDescriptor,
    bind_group_descriptor: BindGroupDescriptor,

    pub fn deinit(model: WindowBoxModel, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group_descriptor.deinit(gctx);
    }
};
