const zgpu = @import("zgpu");

pub const SceneBindGroupLayout = @import("./bind_group_layouts/scene.zig").SceneBindGroupLayout;
pub const RegularBindGroupLayout = @import("./bind_group_layouts/regular.zig").RegularBindGroupLayout;
pub const JointsBindGroupLayout = @import("./bind_group_layouts/joints.zig").JointsBindGroupLayout;
pub const TerrainHeightMapBindGroupLayout = @import("./bind_group_layouts/terrain_height_map.zig").TerrainHeightMapBindGroupLayout;
pub const PrimitiveColorizedBindGroupLayout = @import("./bind_group_layouts/primitive.zig").PrimitiveColorizedBindGroupLayout;
pub const ShadowMapBindGroupLayout = @import("./bind_group_layouts/shadow_map.zig").ShadowMapBindGroupLayout;
pub const LinesBindGroupLayout = @import("./bind_group_layouts/lines.zig").LinesBindGroupLayout;
pub const DebugTextureBindGroupLayout = @import("./bind_group_layouts/debug_texture.zig").DebugTextureBindGroupLayout;

pub const BindGroupLayouts = struct {
    scene: SceneBindGroupLayout,
    regular: RegularBindGroupLayout,
    joints: JointsBindGroupLayout,
    cubemap: RegularBindGroupLayout,
    terrain_height_map: TerrainHeightMapBindGroupLayout,
    primitive_colorized: PrimitiveColorizedBindGroupLayout,
    shadow_map: ShadowMapBindGroupLayout,
    lines: LinesBindGroupLayout,
    debug_texture: DebugTextureBindGroupLayout,

    pub fn init(gctx: *zgpu.GraphicsContext) BindGroupLayouts {
        return .{
            .scene = .init(gctx),
            .regular = RegularBindGroupLayout.init(gctx, .tvdim_2d),
            .joints = JointsBindGroupLayout.init(gctx),
            .cubemap = RegularBindGroupLayout.init(gctx, .tvdim_cube),
            .terrain_height_map = TerrainHeightMapBindGroupLayout.init(gctx),
            .primitive_colorized = PrimitiveColorizedBindGroupLayout.init(gctx),
            .shadow_map = ShadowMapBindGroupLayout.init(gctx),
            .lines = LinesBindGroupLayout.init(gctx),
            .debug_texture = DebugTextureBindGroupLayout.init(gctx),
        };
    }

    pub fn deinit(layouts: *BindGroupLayouts, gctx: *zgpu.GraphicsContext) void {
        layouts.scene.deinit(gctx);
        layouts.regular.deinit(gctx);
        layouts.joints.deinit(gctx);
        layouts.cubemap.deinit(gctx);
        layouts.terrain_height_map.deinit(gctx);
        layouts.primitive_colorized.deinit(gctx);
        layouts.shadow_map.deinit(gctx);
        layouts.lines.deinit(gctx);
        layouts.debug_texture.deinit(gctx);
    }
};
