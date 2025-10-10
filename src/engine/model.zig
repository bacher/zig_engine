const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const ModelDescriptor = @import("./display_object_descriptors/model_descriptor.zig").ModelDescriptor;
const WindowBoxDescriptor = @import("./display_object_descriptors/window_box_descriptor.zig").WindowBoxDescriptor;
const SkyBoxDescriptor = @import("./display_object_descriptors/skybox_descriptor.zig").SkyBoxDescriptor;
const SkyBoxCubemapDescriptor = @import("./display_object_descriptors/skybox_cubemap_descriptor.zig").SkyBoxCubemapDescriptor;
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

// TODO:
// SkyBoxModel and Model are essentially the same type, but I had to distinguish them
// because I need something to be able to choose the right pipeline.
// So maybe it makes sense to reuse Model but add some additional flag to address
// pipeline problem.
pub const SkyBoxModel = struct {
    model_descriptor: SkyBoxDescriptor,
    bind_group_descriptor: BindGroupDescriptor,

    pub fn deinit(model: SkyBoxModel, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group_descriptor.deinit(gctx);
    }
};

// TODO:
// SkyBoxModel and Model are essentially the same type, but I had to distinguish them
// because I need something to be able to choose the right pipeline.
// So maybe it makes sense to reuse Model but add some additional flag to address
// pipeline problem.
pub const SkyBoxCubemapModel = struct {
    model_descriptor: SkyBoxCubemapDescriptor,
    bind_group_descriptor: BindGroupDescriptor,

    pub fn deinit(model: SkyBoxCubemapModel, gctx: *zgpu.GraphicsContext) void {
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
