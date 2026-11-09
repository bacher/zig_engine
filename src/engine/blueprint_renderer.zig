//! Noncolliding instanced blueprint blocks and twelve square-section hazard rails.
const std = @import("std");
const builtin = @import("builtin");
const WorldLayout = @import("world_layout.zig").WorldLayout;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const Camera = @import("camera.zig").Camera;
const BlockType = @import("voxel/voxel_chunk.zig").BlockType;
const chunks = @import("chunk_utils.zig");
const shader = (if (WorldLayout.wrap_x) "const BLUEPRINT_WRAP_X = true;\n" else "const BLUEPRINT_WRAP_X = false;\n") ++ @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/adaptive_geometry.wgsl") ++ @embedFile("shaders/voxel/material_color.wgsl") ++ @embedFile("shaders/blueprint.wgsl");
pub const capacity = 1_100_000;
pub const frame_instance_count: u32 = 12;
pub const Cell = @Vector(3, i64);
pub const ChunkId = chunks.ChunkId;
pub const miniature_chunk_capacity = 4096;
/// Compact, camera-independent source. A chunk never reserves unused cell space.
pub const MiniatureCell = extern struct {
    local: [3]u32,
    material: u32,
};
pub const MiniatureError = error{ OutOfMemory, InvalidMiniatureChunk, MiniatureCapacityExceeded, MiniatureChunkPending };
/// The renderer owns the reservation and resources until commit or discard.
/// Tokens survive map growth and can safely be discarded after unload/clear.
pub const PreparedMiniatureChunk = struct { id: ChunkId, token: u64 };
pub const MiniatureCacheStats = struct {
    cache_builds: u64 = 0,
    source_upload_bytes: u64 = 0,
    cache_releases: u64 = 0,
    uniform_upload_bytes: u64 = 0,
    draw_calls: u64 = 0,
    cached_instances: u32 = 0,
    pending_instances: u32 = 0,
    projected_instances: u32 = 0,
    cached_chunks: u32 = 0,
    pending_chunks: u32 = 0,
};
pub const Instance = extern struct {
    position: [4]f32,
    scale: [4]f32,
    material: [4]u32,
};
fn relativePosition(camera: *const Camera, cell: Cell) @Vector(3, f32) {
    var chunk: @Vector(3, i32) = undefined;
    var local: @Vector(3, f32) = undefined;
    inline for (0..3) |axis| {
        chunk[axis] = @intCast(@divFloor(cell[axis], chunks.CHUNK_SIZE));
        local[axis] = @floatFromInt(@mod(cell[axis], chunks.CHUNK_SIZE));
    }
    return @as(@Vector(3, f32), @floatFromInt(camera.layout.getChunkDelta(chunk, camera.chunk))) * @as(@Vector(3, f32), @splat(chunks.CHUNK_SIZE)) + local;
}
pub fn blockInstance(camera: *const Camera, cell: Cell, material: BlockType, miniature: bool, invalid: bool) Instance {
    const scale: f32 = if (miniature) 0.25 else 1;
    const position = relativePosition(camera, cell) + @as(@Vector(3, f32), @splat((1 - scale) / 2));
    return .{ .position = .{ position[0], position[1], position[2], 0 }, .scale = .{ scale, scale, scale, 0 }, .material = .{ @intFromEnum(material), if (invalid) 2 else 0, 0, 0 } };
}
pub fn appendFrame(list: *std.ArrayList(Instance), allocator: std.mem.Allocator, camera: *const Camera, minimum: Cell, size: [3]u32) !void {
    // Pick one periodic image from the middle cell, rather than a potentially
    // distant minimum corner. Keep the twelve rails continuous. Reuse the one
    // existing coordinate conversion; the nonwrapping offset compiles to zero.
    const center_offset: i64 = if (WorldLayout.wrap_x) size[0] / 2 else 0;
    const base = relativePosition(camera, minimum + Cell{ center_offset, 0, 0 }) -
        @Vector(3, f32){ @floatFromInt(center_offset), 0, 0 };
    const thickness: f32 = 0.035;
    inline for (0..3) |axis| {
        const other_a = (axis + 1) % 3;
        const other_b = (axis + 2) % 3;
        for (0..4) |corner| {
            var position = base - @as(@Vector(3, f32), @splat(thickness / 2));
            position[other_a] += if ((corner & 1) != 0) @as(f32, @floatFromInt(size[other_a])) else 0;
            position[other_b] += if ((corner & 2) != 0) @as(f32, @floatFromInt(size[other_b])) else 0;
            var scale: [4]f32 = .{ thickness, thickness, thickness, 0 };
            scale[axis] = @as(f32, @floatFromInt(size[axis])) + thickness;
            try list.append(allocator, .{ .position = .{ position[0], position[1], position[2], 0 }, .scale = scale, .material = .{ 1, 1, 0, 0 } });
        }
    }
}
/// An immutable definition is borrowed only while building the selected source.
/// Change generation whenever an ID can refer to a different definition lifetime.
pub const Preview = struct {
    definition_id: u64,
    generation: u64,
    size: [3]u32,
    cells: []const BlockType,
    target_count: u32,
    origin: ?[3]u32 = null,
    rotation: u2,
};

/// Full cubes keep their world-axis vertices, normals and UVs. Only these local
/// cell offsets rotate in the preview vertex shader.
const PreviewInstance = extern struct {
    local: [3]u32,
    material: u32,
};
const Transform = extern struct {
    clip_from_chunk: zmath.Mat,
    origin_chunk: [4]i32 = .{ 0, 0, 0, 0 },
    camera_chunk: [4]i32 = .{ 0, 0, 0, 0 },
    origin_local_and_width: [4]u32 = .{ 0, 0, 0, 0 },
    size_and_rotation: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const PreviewError = error{ OutOfMemory, InvalidPreviewDefinition, PreviewCapacityExceeded };

pub const PreviewCacheStats = struct {
    cache_builds: u64 = 0,
    source_upload_bytes: u64 = 0,
    cache_releases: u64 = 0,
    cached_instances: u32 = 0,
};

const PreviewCache = struct {
    definition_id: u64,
    generation: u64,
    size: [3]u32,
    instance_count: u32,
    uniform: zgpu.BufferHandle,
    instances: zgpu.BufferHandle,
    binding: zgpu.BindGroupHandle,

    fn matches(self: PreviewCache, preview: Preview) bool {
        return self.definition_id == preview.definition_id and self.generation == preview.generation;
    }
    fn release(self: PreviewCache, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.binding);
        gctx.releaseResource(self.instances);
        gctx.releaseResource(self.uniform);
    }
};

const MiniatureChunkCache = struct {
    chunk: @Vector(3, i32),
    revision: u64,
    instance_count: u32,
    uniform: zgpu.BufferHandle,
    instances: zgpu.BufferHandle,
    binding: zgpu.BindGroupHandle,

    fn release(self: MiniatureChunkCache, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.binding);
        gctx.releaseResource(self.instances);
        gctx.releaseResource(self.uniform);
    }
};
const MiniaturePending = struct {
    token: u64,
    source: ?MiniatureChunkCache,
    reuse: bool = false,
};
const MiniatureEntry = struct {
    displayed: ?MiniatureChunkCache = null,
    pending: ?MiniaturePending = null,
};

fn miniatureTransform(camera: *const Camera, chunk: @Vector(3, i32)) Transform {
    return .{
        .clip_from_chunk = camera.clip_from_world_chunked,
        .origin_chunk = .{ chunk[0], chunk[1], chunk[2], 0 },
        .camera_chunk = .{ camera.chunk[0], camera.chunk[1], camera.chunk[2], 0 },
        .origin_local_and_width = .{ 0, 0, 0, @intCast(camera.layout.size_in_chunks[0]) },
    };
}

fn previewTransform(camera: *const Camera, preview: Preview) Transform {
    const origin = preview.origin.?;
    var result: Transform = .{ .clip_from_chunk = camera.clip_from_world_chunked };
    inline for (0..3) |axis| {
        // u32 block coordinates, including a full blueprint offset, fit signed
        // chunk coordinates; never subtract the camera into a narrowed i32.
        result.origin_chunk[axis] = @intCast(origin[axis] / chunks.CHUNK_SIZE);
        result.camera_chunk[axis] = camera.chunk[axis];
        result.origin_local_and_width[axis] = origin[axis] % chunks.CHUNK_SIZE;
        result.size_and_rotation[axis] = preview.size[axis];
    }
    result.origin_local_and_width[3] = @intCast(camera.layout.size_in_chunks[0]);
    result.size_and_rotation[3] = preview.rotation;
    return result;
}

fn rotatedPreviewCell(size: [3]u32, cell: [3]u32, rotation: u2) [3]u32 {
    return switch (rotation) {
        0 => cell,
        1 => .{ cell[1], size[0] - 1 - cell[0], cell[2] },
        2 => .{ size[0] - 1 - cell[0], size[1] - 1 - cell[1], cell[2] },
        3 => .{ size[1] - 1 - cell[1], cell[0], cell[2] },
    };
}

fn previewSource(allocator: std.mem.Allocator, preview: Preview) PreviewError![]PreviewInstance {
    var volume: usize = 1;
    for (preview.size) |extent| {
        if (extent == 0) return error.InvalidPreviewDefinition;
        volume = std.math.mul(usize, volume, extent) catch return error.InvalidPreviewDefinition;
    }
    if (volume != preview.cells.len or preview.target_count > capacity or preview.target_count == 0 or preview.target_count > volume)
        return error.InvalidPreviewDefinition;
    const result = try allocator.alloc(PreviewInstance, preview.target_count);
    errdefer allocator.free(result);
    var count: usize = 0;
    const plane = @as(usize, preview.size[0]) * preview.size[1];
    for (preview.cells, 0..) |material, index| {
        if (material == .none) continue;
        if (count == result.len) return error.InvalidPreviewDefinition;
        result[count] = .{
            .local = .{ @intCast(index % preview.size[0]), @intCast((index / preview.size[0]) % preview.size[1]), @intCast(index / plane) },
            .material = @intFromEnum(material),
        };
        count += 1;
    }
    if (count != result.len) return error.InvalidPreviewDefinition;
    return result;
}

pub const Renderer = struct {
    layout: zgpu.BindGroupLayoutHandle,
    uniform: zgpu.BufferHandle,
    instances: zgpu.BufferHandle,
    binding: zgpu.BindGroupHandle,
    pipeline: zgpu.RenderPipelineHandle,
    preview_pipeline: zgpu.RenderPipelineHandle,
    miniature_pipeline: zgpu.RenderPipelineHandle,
    occluded_pipeline: zgpu.RenderPipelineHandle,
    allocated_capacity: usize = 1024,
    preview_cache: ?PreviewCache = null,
    preview_stats: if (builtin.is_test) PreviewCacheStats else void = if (builtin.is_test) .{} else {},
    miniature_chunks: std.AutoHashMap(ChunkId, MiniatureEntry),
    miniature_token: u64 = 0,
    miniature_cached_instances: u32 = 0,
    miniature_pending_instances: u32 = 0,
    miniature_projected_instances: u32 = 0,
    miniature_pending_chunks: u32 = 0,
    miniature_stats: if (builtin.is_test) MiniatureCacheStats else void = if (builtin.is_test) .{} else {},

    pub fn init(gctx: *zgpu.GraphicsContext, atlas_layout: zgpu.BindGroupLayoutHandle, format: wgpu.TextureFormat) Renderer {
        return initWithAllocator(gctx, atlas_layout, format, std.heap.page_allocator);
    }

    pub fn initWithAllocator(gctx: *zgpu.GraphicsContext, atlas_layout: zgpu.BindGroupLayoutHandle, format: wgpu.TextureFormat, allocator: std.mem.Allocator) Renderer {
        // Storage is an array of 16-byte words: three words for each dynamic
        // Instance and one word for each cached PreviewInstance.
        const layout = gctx.createBindGroupLayout(&.{ zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, @sizeOf(Transform)), zgpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, @sizeOf(PreviewInstance)) });
        const uniform = gctx.createBuffer(.{ .label = "blueprint camera", .usage = .{ .uniform = true, .copy_dst = true }, .size = @sizeOf(Transform) });
        const instances = gctx.createBuffer(.{ .label = "visible blueprint instances", .usage = .{ .storage = true, .copy_dst = true }, .size = @sizeOf(Instance) * 1024 });
        const binding = gctx.createBindGroup(layout, &.{ .{ .binding = 0, .buffer_handle = uniform, .size = @sizeOf(Transform) }, .{ .binding = 1, .buffer_handle = instances, .size = @sizeOf(Instance) * 1024 } });
        const pipeline_layout = gctx.createPipelineLayout(&.{ layout, atlas_layout });
        defer gctx.releaseResource(pipeline_layout);
        const module = zgpu.createWgslShaderModule(gctx.device, shader, "blueprints");
        defer module.release();
        const targets = [_]wgpu.ColorTargetState{.{ .format = format }};
        const pipeline = gctx.createRenderPipeline(pipeline_layout, .{ .label = "blueprints", .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back }, .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less_equal }, .vertex = .{ .module = module, .entry_point = "vs" }, .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len } });
        const preview_pipeline = gctx.createRenderPipeline(pipeline_layout, .{ .label = "cached blueprint preview", .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back }, .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less_equal }, .vertex = .{ .module = module, .entry_point = "vs_preview" }, .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len } });
        const miniature_pipeline = gctx.createRenderPipeline(pipeline_layout, .{ .label = "cached blueprint miniatures", .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back }, .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less_equal }, .vertex = .{ .module = module, .entry_point = "vs_miniature" }, .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len } });
        const occluded_targets = [_]wgpu.ColorTargetState{.{ .format = format, .blend = &.{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
        } }};
        const occluded_pipeline = gctx.createRenderPipeline(pipeline_layout, .{
            .label = "occluded capture frame",
            .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back },
            .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = false, .depth_compare = .greater },
            .vertex = .{ .module = module, .entry_point = "vs" },
            .fragment = &.{ .module = module, .entry_point = "fs_occluded", .targets = &occluded_targets, .target_count = occluded_targets.len },
        });
        return .{ .layout = layout, .uniform = uniform, .instances = instances, .binding = binding, .pipeline = pipeline, .preview_pipeline = preview_pipeline, .miniature_pipeline = miniature_pipeline, .occluded_pipeline = occluded_pipeline, .miniature_chunks = .init(allocator) };
    }
    pub fn deinit(self: Renderer, gctx: *zgpu.GraphicsContext) void {
        var mutable = self;
        mutable.clearMiniatures(gctx);
        mutable.miniature_chunks.deinit();
        if (self.preview_cache) |cache| cache.release(gctx);
        gctx.releaseResource(self.occluded_pipeline);
        gctx.releaseResource(self.preview_pipeline);
        gctx.releaseResource(self.miniature_pipeline);
        gctx.releaseResource(self.pipeline);
        gctx.releaseResource(self.binding);
        gctx.releaseResource(self.instances);
        gctx.releaseResource(self.uniform);
        gctx.releaseResource(self.layout);
    }

    /// Prepare does not change displayed geometry. Metadata is reserved before
    /// GPU allocation, making commit allocation-free after the terrain upload.
    /// Logical occupancy reserves max(old,new) until commit, so cancellation can
    /// always preserve old geometry within capacity. Displayed plus staged
    /// source data is separately capped at twice that (35.2 MB). At most 4096
    /// unique nonempty/staged chunks and 4096 preparations may be retained.
    pub fn prepareMiniatureChunk(self: *Renderer, gctx: *zgpu.GraphicsContext, id: ChunkId, chunk: @Vector(3, i32), revision: u64, cells: []const MiniatureCell) MiniatureError!PreparedMiniatureChunk {
        const previous = self.miniature_chunks.get(id);
        if (previous) |entry| if (entry.pending != null) return error.MiniatureChunkPending;
        const displayed = if (previous) |entry| entry.displayed else null;
        const old_count = if (displayed) |source| source.instance_count else 0;
        const reuse = if (displayed) |source| source.revision == revision and @reduce(.And, source.chunk == chunk) else false;
        const count: u32 = if (reuse) old_count else blk: {
            if (cells.len > chunks.CHUNK_SIZE * chunks.CHUNK_SIZE * chunks.CHUNK_SIZE) return error.InvalidMiniatureChunk;
            for (cells) |cell| {
                for (cell.local) |axis| if (axis >= chunks.CHUNK_SIZE) return error.InvalidMiniatureChunk;
                const material = std.enums.fromInt(BlockType, cell.material) orelse return error.InvalidMiniatureChunk;
                if (material == .none) return error.InvalidMiniatureChunk;
            }
            break :blk @intCast(cells.len);
        };
        if (previous == null and count == 0) return .{ .id = id, .token = 0 };
        const pending_count = if (reuse) 0 else count;
        const projected = self.miniature_projected_instances + (count -| old_count);
        if (projected > capacity or
            self.miniature_cached_instances + self.miniature_pending_instances + pending_count > 2 * capacity or
            self.miniature_pending_chunks == miniature_chunk_capacity or
            (previous == null and self.miniature_chunks.count() == miniature_chunk_capacity)) return error.MiniatureCapacityExceeded;

        // Reserve first. An allocator failure preserves both current geometry
        // and every earlier preparation, without creating any GPU resource.
        const entry = if (previous != null) self.miniature_chunks.getPtr(id).? else blk: {
            const inserted = try self.miniature_chunks.getOrPut(id);
            inserted.value_ptr.* = .{};
            break :blk inserted.value_ptr;
        };
        var source: ?MiniatureChunkCache = null;
        if (!reuse and count != 0) {
            const byte_size = @sizeOf(MiniatureCell) * cells.len;
            const uniform = gctx.createBuffer(.{ .label = "blueprint miniature chunk transform", .usage = .{ .uniform = true, .copy_dst = true }, .size = @sizeOf(Transform) });
            const instances = gctx.createBuffer(.{ .label = "blueprint miniature chunk cells", .usage = .{ .storage = true, .copy_dst = true }, .size = byte_size });
            const binding = gctx.createBindGroup(self.layout, &.{ .{ .binding = 0, .buffer_handle = uniform, .size = @sizeOf(Transform) }, .{ .binding = 1, .buffer_handle = instances, .size = byte_size } });
            gctx.queue.writeBuffer(gctx.lookupResource(instances).?, 0, MiniatureCell, cells);
            source = .{ .chunk = chunk, .revision = revision, .instance_count = count, .uniform = uniform, .instances = instances, .binding = binding };
            if (builtin.is_test) {
                self.miniature_stats.cache_builds += 1;
                self.miniature_stats.source_upload_bytes += byte_size;
            }
        }
        self.miniature_token += 1;
        std.debug.assert(self.miniature_token != 0);
        entry.pending = .{ .token = self.miniature_token, .source = source, .reuse = reuse };
        self.miniature_pending_chunks += 1;
        self.miniature_pending_instances += pending_count;
        self.miniature_projected_instances = projected;
        return .{ .id = id, .token = self.miniature_token };
    }

    /// Consume once after the matching terrain representation has been accepted.
    /// A stale handle after unload/clear is harmless and cannot publish new data.
    pub fn commitMiniatureChunk(self: *Renderer, gctx: *zgpu.GraphicsContext, prepared: *PreparedMiniatureChunk) void {
        defer prepared.token = 0;
        if (prepared.token == 0) return;
        const entry = self.miniature_chunks.getPtr(prepared.id) orelse return;
        const pending = entry.pending orelse return;
        if (pending.token != prepared.token) return;
        self.miniature_pending_chunks -= 1;
        entry.pending = null;
        if (pending.reuse) return;
        const old_count = if (entry.displayed) |old| old.instance_count else 0;
        const new_count = if (pending.source) |source| source.instance_count else 0;
        self.miniature_projected_instances -= old_count -| new_count;
        if (entry.displayed) |old| {
            self.miniature_cached_instances -= old.instance_count;
            self.releaseMiniatureSource(gctx, old);
        }
        entry.displayed = pending.source;
        if (pending.source) |source| {
            self.miniature_cached_instances += source.instance_count;
            self.miniature_pending_instances -= source.instance_count;
        } else {
            _ = self.miniature_chunks.remove(prepared.id);
        }
    }

    /// Cancel staged resources and restore their logical occupancy reservation.
    pub fn discardMiniatureChunk(self: *Renderer, gctx: *zgpu.GraphicsContext, prepared: *PreparedMiniatureChunk) void {
        defer prepared.token = 0;
        if (prepared.token == 0) return;
        const entry = self.miniature_chunks.getPtr(prepared.id) orelse return;
        const pending = entry.pending orelse return;
        if (pending.token != prepared.token) return;
        self.miniature_pending_chunks -= 1;
        entry.pending = null;
        if (pending.reuse) return;
        const old_count = if (entry.displayed) |old| old.instance_count else 0;
        if (pending.source) |source| {
            self.miniature_projected_instances -= source.instance_count -| old_count;
            self.miniature_pending_instances -= source.instance_count;
            self.releaseMiniatureSource(gctx, source);
        }
        if (entry.displayed == null) {
            _ = self.miniature_chunks.remove(prepared.id);
        }
    }

    fn releaseMiniatureSource(self: *Renderer, gctx: *zgpu.GraphicsContext, source: MiniatureChunkCache) void {
        source.release(gctx);
        if (builtin.is_test) self.miniature_stats.cache_releases += 1;
    }

    /// Remove displayed and staged representations on chunk unload.
    pub fn removeMiniatureChunk(self: *Renderer, gctx: *zgpu.GraphicsContext, id: ChunkId) void {
        const removed = self.miniature_chunks.fetchRemove(id) orelse return;
        const entry = removed.value;
        const old_count = if (entry.displayed) |source| source.instance_count else 0;
        var projected_count = old_count;
        if (entry.pending) |pending| {
            self.miniature_pending_chunks -= 1;
            if (!pending.reuse) {
                if (pending.source) |source| {
                    projected_count = @max(old_count, source.instance_count);
                    self.miniature_pending_instances -= source.instance_count;
                    self.releaseMiniatureSource(gctx, source);
                }
            }
        }
        self.miniature_projected_instances -= projected_count;
        self.miniature_cached_instances -= old_count;
        if (entry.displayed) |source| self.releaseMiniatureSource(gctx, source);
    }

    pub fn clearMiniatures(self: *Renderer, gctx: *zgpu.GraphicsContext) void {
        var iterator = self.miniature_chunks.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.displayed) |source| self.releaseMiniatureSource(gctx, source);
            if (entry.pending) |pending| if (pending.source) |source| self.releaseMiniatureSource(gctx, source);
        }
        self.miniature_chunks.clearRetainingCapacity();
        self.miniature_cached_instances = 0;
        self.miniature_pending_instances = 0;
        self.miniature_projected_instances = 0;
        self.miniature_pending_chunks = 0;
    }

    pub fn miniatureChunkCount(self: *const Renderer, id: ChunkId) u32 {
        const entry = self.miniature_chunks.get(id) orelse return 0;
        return if (entry.displayed) |source| source.instance_count else 0;
    }

    /// Source counters include preparations, even if later discarded. Live
    /// counts distinguish displayed, physically staged, and logical occupancy.
    pub fn miniatureCacheStats(self: *const Renderer) MiniatureCacheStats {
        var result: MiniatureCacheStats = if (builtin.is_test) self.miniature_stats else .{};
        result.cached_instances = self.miniature_cached_instances;
        result.pending_instances = self.miniature_pending_instances;
        result.projected_instances = self.miniature_projected_instances;
        result.pending_chunks = self.miniature_pending_chunks;
        var iterator = self.miniature_chunks.valueIterator();
        while (iterator.next()) |entry| if (entry.displayed != null) {
            result.cached_chunks += 1;
        };
        return result;
    }

    /// One draw per visible nonempty chunk; work follows chunk count, never cell
    /// count. Visibility does not allocate, rebuild sources, or change residency.
    pub fn drawMiniatures(self: *Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, atlas: wgpu.BindGroup, camera: *const Camera, visible_chunk_ids: []const ChunkId, max_instances: u32) MiniatureError!void {
        var count: usize = 0;
        for (visible_chunk_ids) |id| {
            count += self.miniatureChunkCount(id);
            if (count > max_instances or count > capacity) return error.MiniatureCapacityExceeded;
        }
        if (count == 0) return;
        pass.setBindGroup(1, atlas, null);
        pass.setPipeline(gctx.lookupResource(self.miniature_pipeline).?);
        for (visible_chunk_ids) |id| {
            const entry = self.miniature_chunks.get(id) orelse continue;
            const source = entry.displayed orelse continue;
            const transform = miniatureTransform(camera, source.chunk);
            gctx.queue.writeBuffer(gctx.lookupResource(source.uniform).?, 0, Transform, &.{transform});
            pass.setBindGroup(0, gctx.lookupResource(source.binding).?, null);
            pass.draw(36, source.instance_count, 0, 0);
            if (builtin.is_test) {
                self.miniature_stats.uniform_upload_bytes += @sizeOf(Transform);
                self.miniature_stats.draw_calls += 1;
            }
        }
    }

    pub fn clearPreview(self: *Renderer, gctx: *zgpu.GraphicsContext) void {
        if (self.preview_cache) |cache| {
            cache.release(gctx);
            self.preview_cache = null;
            if (builtin.is_test) self.preview_stats.cache_releases += 1;
        }
    }

    /// Counters are stored only in test builds. The live instance count also
    /// allows lifecycle tests to distinguish a hidden source from a released one.
    pub fn previewCacheStats(self: *const Renderer) PreviewCacheStats {
        var result: PreviewCacheStats = if (builtin.is_test) self.preview_stats else .{};
        result.cached_instances = if (self.preview_cache) |cache| cache.instance_count else 0;
        return result;
    }

    fn syncPreview(self: *Renderer, gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator, preview: ?Preview) PreviewError!void {
        if (self.preview_cache) |cache| {
            if (preview == null or !cache.matches(preview.?)) self.clearPreview(gctx);
        }
        const selected = preview orelse return;
        if (selected.origin == null or self.preview_cache != null) return;
        const source = try previewSource(allocator, selected);
        defer allocator.free(source);
        const byte_size = @sizeOf(PreviewInstance) * source.len;
        const uniform = gctx.createBuffer(.{ .label = "blueprint preview transform", .usage = .{ .uniform = true, .copy_dst = true }, .size = @sizeOf(Transform) });
        const instances = gctx.createBuffer(.{ .label = "cached blueprint local cells", .usage = .{ .storage = true, .copy_dst = true }, .size = byte_size });
        const binding = gctx.createBindGroup(self.layout, &.{ .{ .binding = 0, .buffer_handle = uniform, .size = @sizeOf(Transform) }, .{ .binding = 1, .buffer_handle = instances, .size = byte_size } });
        gctx.queue.writeBuffer(gctx.lookupResource(instances).?, 0, PreviewInstance, source);
        self.preview_cache = .{ .definition_id = selected.definition_id, .generation = selected.generation, .size = selected.size, .instance_count = selected.target_count, .uniform = uniform, .instances = instances, .binding = binding };
        if (builtin.is_test) {
            self.preview_stats.cache_builds += 1;
            self.preview_stats.source_upload_bytes += byte_size;
        }
    }

    /// Compatible dynamic-only entry point for rails and miniatures.
    pub fn draw(self: *Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, atlas: wgpu.BindGroup, camera: *const Camera, instances: []const Instance, selection_frame_start: ?u32) void {
        self.drawWithPreview(gctx, pass, atlas, camera, instances, selection_frame_start, std.heap.page_allocator, null) catch unreachable;
    }

    /// The optional start selects exactly one complete frame in the dynamic
    /// instance buffer. Preview source upload happens only when its immutable
    /// definition key changes; movement and rotation update its own uniform.
    pub fn drawWithPreview(self: *Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, atlas: wgpu.BindGroup, camera: *const Camera, instances: []const Instance, selection_frame_start: ?u32, allocator: std.mem.Allocator, preview: ?Preview) PreviewError!void {
        std.debug.assert(instances.len <= capacity);
        if (selection_frame_start) |start| {
            std.debug.assert(@as(usize, start) + frame_instance_count <= instances.len);
            for (instances[start..][0..frame_instance_count]) |rail| std.debug.assert(rail.material[1] == 1);
        }
        // Clear stale sources before drawing even when this replacement fails.
        // Dynamic miniatures/rails still render before surfacing a preview error.
        var preview_error: ?PreviewError = null;
        if (preview) |selected| {
            if (selected.origin != null and selected.target_count > capacity - instances.len) {
                self.clearPreview(gctx);
                preview_error = error.PreviewCapacityExceeded;
            }
        }
        if (preview_error == null) self.syncPreview(gctx, allocator, preview) catch |err| {
            preview_error = err;
        };
        if (instances.len > 0) {
            if (instances.len > self.allocated_capacity) {
                const next_capacity: usize = @min(capacity, std.math.ceilPowerOfTwoAssert(usize, instances.len));
                gctx.releaseResource(self.binding);
                gctx.releaseResource(self.instances);
                self.instances = gctx.createBuffer(.{ .label = "visible blueprint instances", .usage = .{ .storage = true, .copy_dst = true }, .size = @sizeOf(Instance) * next_capacity });
                self.binding = gctx.createBindGroup(self.layout, &.{ .{ .binding = 0, .buffer_handle = self.uniform, .size = @sizeOf(Transform) }, .{ .binding = 1, .buffer_handle = self.instances, .size = @sizeOf(Instance) * next_capacity } });
                self.allocated_capacity = next_capacity;
            }
            const transform: Transform = .{ .clip_from_chunk = camera.clip_from_world_chunked };
            gctx.queue.writeBuffer(gctx.lookupResource(self.uniform).?, 0, Transform, &.{transform});
            gctx.queue.writeBuffer(gctx.lookupResource(self.instances).?, 0, Instance, instances);
            pass.setBindGroup(0, gctx.lookupResource(self.binding).?, null);
            pass.setBindGroup(1, atlas, null);
            if (selection_frame_start) |start| {
                pass.setPipeline(gctx.lookupResource(self.occluded_pipeline).?);
                pass.draw(36, frame_instance_count, 0, start);
            }
            pass.setPipeline(gctx.lookupResource(self.pipeline).?);
            pass.draw(36, @intCast(instances.len), 0, 0);
        }
        if (preview_error) |err| return err;
        if (preview) |selected| {
            if (selected.origin != null) {
                const cache = self.preview_cache.?;
                std.debug.assert(std.mem.eql(u32, &cache.size, &selected.size));
                std.debug.assert(cache.instance_count == selected.target_count);
                const transform = previewTransform(camera, selected);
                gctx.queue.writeBuffer(gctx.lookupResource(cache.uniform).?, 0, Transform, &.{transform});
                pass.setBindGroup(0, gctx.lookupResource(cache.binding).?, null);
                pass.setBindGroup(1, atlas, null);
                pass.setPipeline(gctx.lookupResource(self.preview_pipeline).?);
                pass.draw(36, cache.instance_count, 0, 0);
            }
        }
    }
};

test "frame consists of twelve square section rails" {
    const layout = try @import("world_layout.zig").WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const camera = Camera.init(&layout, 1);
    var list: std.ArrayList(Instance) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendFrame(&list, std.testing.allocator, &camera, .{ 128, 128, 128 }, .{ 5, 6, 7 });
    try std.testing.expectEqual(12, list.items.len);
    const miniature = blockInstance(&camera, .{ 128, 128, 128 }, .planks, true, false);
    try std.testing.expectEqual(@as(f32, 0.25), miniature.scale[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), miniature.position[0], 0.00001);
}

test "frame anchors its continuous interval by the middle cell near half a world" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var camera = Camera.init(&layout, 1);
    camera.chunk = .{ 5, 4, 4 };
    var list: std.ArrayList(Instance) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacityPrecise(std.testing.allocator, frame_instance_count);
    // Warm frame construction needs no allocation, including after the image
    // change. A failing allocator also prevents extra geometry from hiding here.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const half_thickness: f32 = 0.035 / 2.0;
    for ([_]i64{ -225, 31, 287 }) |minimum_x| {
        list.clearRetainingCapacity();
        try appendFrame(&list, failing.allocator(), &camera, .{ minimum_x, 128, 128 }, .{ 127, 5, 7 });
        try std.testing.expectEqual(frame_instance_count, list.items.len);
        const expected_x: f32 = if (WorldLayout.wrap_x) -129 else @floatFromInt(minimum_x - 160);
        try std.testing.expectApproxEqAbs(expected_x, list.items[0].position[0] + half_thickness, 0.00002);
        try std.testing.expectApproxEqAbs(expected_x + 127, list.items[6].position[0] + half_thickness, 0.00002);
        try std.testing.expectApproxEqAbs(@as(f32, 0), list.items[0].position[1] + half_thickness, 0.00002);
        try std.testing.expectApproxEqAbs(@as(f32, 0), list.items[0].position[2] + half_thickness, 0.00002);
        try std.testing.expectApproxEqAbs(@as(f32, 127.035), list.items[0].scale[0], 0.00002);
        try std.testing.expectApproxEqAbs(@as(f32, 5.035), list.items[4].scale[1], 0.00002);
        try std.testing.expectApproxEqAbs(@as(f32, 7.035), list.items[8].scale[2], 0.00002);
    }
    if (comptime WorldLayout.wrap_x) {
        // The nearby last cell lies just inside the corrected far face at -2.
        const last = blockInstance(&camera, .{ 157, 128, 128 }, .planks, true, false);
        try std.testing.expectEqual(@as(f32, -2.625), last.position[0]);
    }
    list.clearRetainingCapacity();
    try appendFrame(&list, failing.allocator(), &camera, .{ 31, 128, 128 }, .{ 1, 1, 1 });
    try std.testing.expectEqual(frame_instance_count, list.items.len);
    const original = relativePosition(&camera, .{ 31, 128, 128 });
    try std.testing.expectApproxEqAbs(original[0], list.items[0].position[0] + half_thickness, 0.00002);
    try std.testing.expect(!failing.has_induced_failure);
}

// Integer operations and conversion order used by vs_preview, kept independent
// of relativePosition so full-range and antipode tests compare both paths.
fn previewShaderPosition(transform: Transform, cell: [3]u32) @Vector(3, f32) {
    const offset = rotatedPreviewCell(transform.size_and_rotation[0..3].*, cell, @intCast(transform.size_and_rotation[3]));
    var result: @Vector(3, f32) = undefined;
    inline for (0..3) |axis| {
        const local = transform.origin_local_and_width[axis] + offset[axis] % chunks.CHUNK_SIZE;
        const carry = offset[axis] / chunks.CHUNK_SIZE + local / chunks.CHUNK_SIZE;
        const chunk = transform.origin_chunk[axis] + @as(i32, @intCast(carry));
        const camera = transform.camera_chunk[axis];
        var delta: i64 = @as(i64, chunk) - camera;
        if (axis == 0 and WorldLayout.wrap_x) {
            const width = transform.origin_local_and_width[3];
            const mask = width - 1;
            const a = @as(u32, @bitCast(chunk)) & mask;
            const b = @as(u32, @bitCast(camera)) & mask;
            delta = @as(i64, a) - b;
            if (delta > width / 2) delta -= width;
            if (delta < -@as(i64, width / 2)) delta += width;
        }
        result[axis] = @as(f32, @floatFromInt(delta)) * chunks.CHUNK_SIZE + @as(f32, @floatFromInt(local % chunks.CHUNK_SIZE));
    }
    return result;
}

test "preview source is compact local occupied cells and allocation failure is recoverable" {
    const selected: Preview = .{ .definition_id = 1, .generation = 1, .size = .{ 2, 2, 1 }, .cells = &.{ .planks, .none, .dirt, .sand }, .target_count = 3, .rotation = 0 };
    const source = try previewSource(std.testing.allocator, selected);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PreviewInstance));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Transform));
    try std.testing.expectEqual(@as(usize, 3), source.len);
    try std.testing.expectEqualDeep([3]u32{ 0, 0, 0 }, source[0].local);
    try std.testing.expectEqualDeep([3]u32{ 0, 1, 0 }, source[1].local);
    try std.testing.expectEqualDeep([3]u32{ 1, 1, 0 }, source[2].local);
    try std.testing.expectEqual(@intFromEnum(BlockType.sand), source[2].material);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, previewSource(failing.allocator(), selected));
    var malformed = selected;
    malformed.target_count = 2;
    try std.testing.expectError(error.InvalidPreviewDefinition, previewSource(std.testing.allocator, malformed));
    malformed = selected;
    malformed.size = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
    try std.testing.expectError(error.InvalidPreviewDefinition, previewSource(std.testing.allocator, malformed));
}

test "preview rotates cell offsets while preserving quarter-turn dimensions" {
    const size: [3]u32 = .{ 5, 3, 2 };
    const local: [3]u32 = .{ 1, 2, 1 };
    const expected = [_][3]u32{ .{ 1, 2, 1 }, .{ 2, 3, 1 }, .{ 3, 0, 1 }, .{ 0, 1, 1 } };
    for (expected, 0..) |result, rotation| {
        try std.testing.expectEqualDeep(result, rotatedPreviewCell(size, local, @intCast(rotation)));
    }
}

test "preview coordinates match per-cell wrapping across seams ties rotations and camera chunks" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var camera = Camera.init(&layout, 1);
    const origins = [_][3]u32{ .{ 0, 1, 2 }, .{ 31, 31, 31 }, .{ 127, 63, 32 }, .{ 128, 64, 63 }, .{ 223, 65, 64 }, .{ 255, 95, 95 } };
    const camera_xs = [_]i32{ -1, 0, 3, 4, 7, 8, std.math.minInt(i32), std.math.maxInt(i32) };
    for (origins) |origin| {
        for (camera_xs) |camera_x| {
            camera.chunk = .{ camera_x, -3, 8 };
            for (0..4) |rotation| {
                const preview: Preview = .{ .definition_id = 1, .generation = 1, .size = .{ 5, 3, 2 }, .cells = &.{}, .target_count = 1, .origin = origin, .rotation = @intCast(rotation) };
                const transform = previewTransform(&camera, preview);
                for (0..2) |z| for (0..3) |y| for (0..5) |x| {
                    const cell: [3]u32 = .{ @intCast(x), @intCast(y), @intCast(z) };
                    const rotated = rotatedPreviewCell(preview.size, cell, preview.rotation);
                    var world: Cell = undefined;
                    inline for (0..3) |axis| world[axis] = @as(i64, origin[axis]) + rotated[axis];
                    try std.testing.expectEqual(relativePosition(&camera, world), previewShaderPosition(transform, cell));
                };
            }
        }
    }
    // Raw +half after a seam carry is canonical -half, not +half.
    camera.chunk = .{ 4, 0, 0 };
    const crossing: Preview = .{ .definition_id = 1, .generation = 1, .size = .{ 2, 1, 1 }, .cells = &.{}, .target_count = 1, .origin = .{ 255, 0, 0 }, .rotation = 0 };
    const crossed = previewShaderPosition(previewTransform(&camera, crossing), .{ 1, 0, 0 });
    try std.testing.expectEqual(@as(f32, if (WorldLayout.wrap_x) -128 else 128), crossed[0]);
}

test "preview chunk conversion preserves largest world and full signed camera differences" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 1 << 26, 2, 2 } });
    var camera = Camera.init(&layout, 1);
    const preview: Preview = .{ .definition_id = 1, .generation = 1, .size = .{ 3, 2, 2 }, .cells = &.{}, .target_count = 1, .origin = .{ (1 << 31) - 1, 31, 31 }, .rotation = 0 };
    const extremes = [_]i32{ std.math.minInt(i32), std.math.maxInt(i32) };
    for (extremes) |camera_x| for (extremes) |camera_y| for (extremes) |camera_z| {
        camera.chunk = .{ camera_x, camera_y, camera_z };
        for ([_][3]u32{ .{ 0, 0, 0 }, .{ 2, 1, 1 } }) |cell| {
            const world: Cell = .{ @as(i64, preview.origin.?[0]) + cell[0], @as(i64, preview.origin.?[1]) + cell[1], @as(i64, preview.origin.?[2]) + cell[2] };
            try std.testing.expectEqual(relativePosition(&camera, world), previewShaderPosition(previewTransform(&camera, preview), cell));
        }
    };
}

test "dense preview source uses one compact staging allocation" {
    const count = 100 * 100 * 32;
    const cells = try std.testing.allocator.alloc(BlockType, count);
    defer std.testing.allocator.free(cells);
    @memset(cells, .planks);
    const selected: Preview = .{ .definition_id = 1, .generation = 1, .size = .{ 100, 100, 32 }, .cells = cells, .target_count = count, .rotation = 0 };
    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const source = try previewSource(tracked.allocator(), selected);
    defer tracked.allocator().free(source);
    try std.testing.expectEqual(@as(usize, 1), tracked.alloc_index);
    try std.testing.expectEqual(@as(usize, 5_120_000), source.len * @sizeOf(PreviewInstance));
    try std.testing.expectEqualDeep([3]u32{ 99, 99, 31 }, source[source.len - 1].local);
}

test "sparse preview volume may exceed occupied instance capacity" {
    const size: [3]u32 = .{ 1100, 1001, 1 };
    const cells = try std.testing.allocator.alloc(BlockType, size[0] * size[1]);
    defer std.testing.allocator.free(cells);
    @memset(cells, .none);
    cells[0] = .planks;
    cells[cells.len - 1] = .dirt;
    const selected: Preview = .{ .definition_id = 1, .generation = 1, .size = size, .cells = cells, .target_count = 2, .rotation = 0 };
    const source = try previewSource(std.testing.allocator, selected);
    defer std.testing.allocator.free(source);
    try std.testing.expect(cells.len > capacity);
    try std.testing.expectEqual(@as(usize, 2), source.len);
    try std.testing.expectEqualDeep([3]u32{ 1099, 1000, 0 }, source[1].local);
}
