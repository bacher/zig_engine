const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const ModelDescriptor = @import("./display_object_descriptors/model_descriptor.zig").ModelDescriptor;
const WindowBoxDescriptor = @import("./display_object_descriptors/window_box_descriptor.zig").WindowBoxDescriptor;
const SkyBoxDescriptor = @import("./display_object_descriptors/skybox_descriptor.zig").SkyBoxDescriptor;
const SkyBoxCubemapDescriptor = @import("./display_object_descriptors/skybox_cubemap_descriptor.zig").SkyBoxCubemapDescriptor;
const PrimitiveDescriptor = @import("./display_object_descriptors/primitive_descriptor.zig").PrimitiveDescriptor;
const CubeWireframeDescriptor = @import("./display_object_descriptors/cube_wireframe_descriptor.zig").CubeWireframeDescriptor;
const BindGroup = @import("./bind_group.zig").BindGroup;
const SkeletalAnimationPlayer = @import("./skeletal_animation.zig");

pub const Model = struct {
    model_descriptor: ModelDescriptor,
    bind_group: BindGroup,
    skeletal_animation: ?SkeletalAnimationPlayer = null,

    pub fn deinit(model: Model, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group.deinit(gctx);
        if (model.skeletal_animation) |animation| {
            animation.deinit();
        }
    }

    pub fn update(model: *Model, gctx: *zgpu.GraphicsContext, time: f32) void {
        if (model.skeletal_animation) |*animation| {
            animation.update(gctx, &model.model_descriptor, time);
        }
    }
};

// TODO:
// SkyBoxModel and Model are essentially the same type, but I had to distinguish them
// because I need something to be able to choose the right pipeline.
// So maybe it makes sense to reuse Model but add some additional flag to address
// pipeline problem.
pub const SkyBoxModel = struct {
    model_descriptor: SkyBoxDescriptor,
    bind_group: BindGroup,

    pub fn deinit(model: SkyBoxModel, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group.deinit(gctx);
    }
};

// TODO:
// SkyBoxModel and Model are essentially the same type, but I had to distinguish them
// because I need something to be able to choose the right pipeline.
// So maybe it makes sense to reuse Model but add some additional flag to address
// pipeline problem.
pub const SkyBoxCubemapModel = struct {
    model_descriptor: SkyBoxCubemapDescriptor,
    bind_group: BindGroup,

    pub fn deinit(model: SkyBoxCubemapModel, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group.deinit(gctx);
    }
};

pub const WindowBoxModel = struct {
    model_descriptor: WindowBoxDescriptor,
    bind_group: BindGroup,

    pub fn deinit(model: WindowBoxModel, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group.deinit(gctx);
    }
};

pub const PrimitiveModel = struct {
    model_descriptor: PrimitiveDescriptor,
    bind_group: BindGroup,

    pub fn deinit(model: PrimitiveModel, gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group.deinit(gctx);
    }
};

pub const CubeWireframeModel = struct {
    model_descriptor: CubeWireframeDescriptor,
    bind_group: BindGroup,

    pub fn deinit(model: @This(), gctx: *zgpu.GraphicsContext) void {
        model.model_descriptor.deinit();
        model.bind_group.deinit(gctx);
    }
};

pub const TerrainHeightMapModel = struct {
    bind_group: BindGroup,

    // `deinit` of TerrainHeightMapModel has different logic than other models.
    // It is not automatically deinitialized by engine.
    pub fn deinit(model: *const TerrainHeightMapModel, gctx: *zgpu.GraphicsContext) void {
        model.bind_group.deinit(gctx);
    }
};
