const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const ModelDescriptor = @import("./display_object_descriptors/model_descriptor.zig").ModelDescriptor;
const WindowBoxDescriptor = @import("./display_object_descriptors/window_box_descriptor.zig").WindowBoxDescriptor;
const PrimitiveDescriptor = @import("./display_object_descriptors/primitive_descriptor.zig").PrimitiveDescriptor;
const BindGroupDescriptor = @import("./bind_group_descriptor.zig").BindGroupDescriptor;

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

pub const PrimitiveModel = struct {
    model_descriptor: PrimitiveDescriptor,
    bind_group_descriptor: BindGroupDescriptor,

    pub fn deinit(model: PrimitiveDescriptor, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group_descriptor.deinit(gctx);
    }
};
