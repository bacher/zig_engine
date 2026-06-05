const zgpu = @import("zgpu");

pub const SceneBindGroupLayout = @import("./bind_group_layouts/scene.zig").SceneBindGroupLayout;
pub const RegularBindGroupLayout = @import("./bind_group_layouts/regular.zig").RegularBindGroupLayout;
pub const JointsBindGroupLayout = @import("./bind_group_layouts/joints.zig").JointsBindGroupLayout;
pub const TerrainHeightMapBindGroupLayout = @import("./bind_group_layouts/terrain_height_map.zig").TerrainHeightMapBindGroupLayout;
pub const PrimitiveColorizedBindGroupLayout = @import("./bind_group_layouts/primitive.zig").PrimitiveColorizedBindGroupLayout;
pub const ShadowMapPassBindGroupLayout = @import("./bind_group_layouts/shadow_map_pass.zig").ShadowMapPassBindGroupLayout;
pub const ShadowMapBindGroupLayout = @import("./bind_group_layouts/shadow_map.zig").ShadowMapBindGroupLayout;
pub const LinesBindGroupLayout = @import("./bind_group_layouts/lines.zig").LinesBindGroupLayout;
pub const DebugTextureBindGroupLayout = @import("./bind_group_layouts/debug_texture.zig").DebugTextureBindGroupLayout;
pub const InstancesBufferBindGroupLayout = @import("./bind_group_layouts/instances_buffer.zig").InstancesBufferBindGroupLayout;

pub const BindGroupLayouts = struct {
    scene: SceneBindGroupLayout,
    regular: RegularBindGroupLayout,
    joints: JointsBindGroupLayout,
    cubemap: RegularBindGroupLayout,
    terrain_height_map: TerrainHeightMapBindGroupLayout,
    primitive_colorized: PrimitiveColorizedBindGroupLayout,
    shadow_map_pass: ShadowMapPassBindGroupLayout,
    shadow_map: ShadowMapBindGroupLayout,
    lines: LinesBindGroupLayout,
    debug_texture: DebugTextureBindGroupLayout,
    instances_buffer: InstancesBufferBindGroupLayout,

    pub fn init(gctx: *zgpu.GraphicsContext) BindGroupLayouts {
        return .{
            .scene = .init(gctx),
            .regular = RegularBindGroupLayout.init(gctx, .tvdim_2d),
            .joints = JointsBindGroupLayout.init(gctx),
            .cubemap = RegularBindGroupLayout.init(gctx, .tvdim_cube),
            .terrain_height_map = TerrainHeightMapBindGroupLayout.init(gctx),
            .primitive_colorized = PrimitiveColorizedBindGroupLayout.init(gctx),
            .shadow_map_pass = ShadowMapPassBindGroupLayout.init(gctx),
            .shadow_map = ShadowMapBindGroupLayout.init(gctx),
            .lines = LinesBindGroupLayout.init(gctx),
            .debug_texture = DebugTextureBindGroupLayout.init(gctx),
            .instances_buffer = InstancesBufferBindGroupLayout.init(gctx),
        };
    }

    pub fn deinit(layouts: *BindGroupLayouts) void {
        layouts.scene.deinit();
        layouts.regular.deinit();
        layouts.joints.deinit();
        layouts.cubemap.deinit();
        layouts.terrain_height_map.deinit();
        layouts.primitive_colorized.deinit();
        layouts.shadow_map_pass.deinit();
        layouts.shadow_map.deinit();
        layouts.lines.deinit();
        layouts.debug_texture.deinit();
        layouts.instances_buffer.deinit();
    }
};
