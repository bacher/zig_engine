const std = @import("std");
const math = std.math;

const gltf_loader = @import("gltf_loader");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const types = @import("../types.zig");
const load_buffer = @import("../load_buffer.zig");
const load_texture = @import("../load_texture.zig");

pub const ModelDescriptor = struct {
    // model: gltf_loader.GltfLoader,
    position: types.BufferDescriptor,
    normal: types.BufferDescriptor,
    texcoord: types.BufferDescriptor,
    index: types.BufferDescriptor,
    color_texture: types.TextureDescriptor,
    geometry_bounds: types.GeometryBounds,
    mesh_y_up: bool = false,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
        allocator: std.mem.Allocator,
        loader: *const gltf_loader.GltfLoader,
        object: *const gltf_loader.SceneObject,
    ) !ModelDescriptor {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const mesh = object.mesh.?;

        const buffers = try loader.loadModelBuffers(arena_allocator, mesh);
        defer buffers.deinit(arena_allocator);

        const material = loader.getObjectMaterial(object);
        // TODO: Do not load the same texture several times. Add cache?
        var color_texture_image = try loader.loadMaterialTextureData(material) orelse try loader.loadTextureData("../uv-test.png");
        defer color_texture_image.deinit();

        const positions_buffer_info = try load_buffer.loadBufferIntoGpu(gctx, .vertex, buffers.positions);
        const normal_buffer_info = try load_buffer.loadBufferIntoGpu(gctx, .vertex, buffers.normals);
        const texcoord_buffer_info = try load_buffer.loadBufferIntoGpu(gctx, .vertex, buffers.texcoord);
        const index_buffer_info = try load_buffer.loadBufferIntoGpu(gctx, .index, buffers.indexes);

        const color_texture = try load_texture.loadTextureIntoGpu(
            gctx,
            allocator,
            color_texture_image,
            .{ .generate_mipmaps = color_texture_image.width == color_texture_image.height },
        );

        return ModelDescriptor{
            // .model = model,
            .position = positions_buffer_info,
            .normal = normal_buffer_info,
            .texcoord = texcoord_buffer_info,
            .index = index_buffer_info,
            .color_texture = color_texture,
            .geometry_bounds = .{
                .min = mesh.geometry_bounds.min,
                .max = mesh.geometry_bounds.max,
                .radius = calcBoundingRadius(mesh.geometry_bounds),
            },
            .mesh_y_up = true,
        };
    }

    pub fn deinit(model_description: ModelDescriptor) void {
        _ = model_description;
        // model_description.model.deinit();
    }
};

fn calcBoundingRadius(geometry_bounds: gltf_loader.GeometryBounds) f32 {
    const min = geometry_bounds.min;
    const max = geometry_bounds.max;

    const x = @max(@abs(min[0]), @abs(max[0]));
    const y = @max(@abs(min[1]), @abs(max[1]));
    const z = @max(@abs(min[2]), @abs(max[2]));

    return len(.{ x, y, z });
}

fn len(vec: [3]f64) f32 {
    return @floatCast(
        math.sqrt(vec[0] * vec[0] + vec[1] * vec[1] + vec[2] * vec[2]),
    );
}
