//! Owner-neutral cargo and loose-pallet batches, independent of terrain surfaces.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const BindGroupLayouts = @import("bind_group_layouts.zig").BindGroupLayouts;
const targets = @import("pipelines/_first_pass_color_targets.zig").first_pass_color_with_normals_targets;

pub const Face = extern struct { local: [3]u32, material: u32, direction: u32 };
pub const Instance = extern struct { local: [3]u32, material: u32 };
pub const Marker = extern struct { local: [3]u32, material: u32, disabled: u32 = 0 };
pub const Source = struct {
    chunk: @Vector(3, i32),
    revision: u64,
    faces: []const Face = &.{},
    models: []const Instance = &.{},
    packaging: []const Instance = &.{},
    pallets: []const Instance = &.{},
    markers: []const Marker = &.{},
};
pub const GPU_Face = extern struct { local: [3]u32, material: u32, direction: u32, owner: u32 };
pub const GPU_Instance = extern struct { local: [3]u32, material: u32, owner: u32 };
pub const GPU_Marker = extern struct { local: [3]u32, material: u32, disabled: u32, owner: u32 };
pub const model_vertex_count: u32 = 288;
pub const packaging_vertex_count: u32 = model_vertex_count + 36;
pub const category_count = 5;
const color_source_group = 3;
const shadow_source_group = 2;
const vertex_counts = [category_count]u32{ 6, model_vertex_count, packaging_vertex_count, model_vertex_count, 6 };
const entry_points = [category_count][*:0]const u8{ "faces", "models", "packaging", "pallets", "markers" };
pub const geometry_shader = @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/adaptive_geometry.wgsl") ++ @embedFile("shaders/voxel/pallet_geometry.wgsl") ++ @embedFile("shaders/packed_geometry.wgsl");
pub const color_shader = std.fmt.comptimePrint("const PACKED_SOURCE_GROUP = {d}u;\n", .{color_source_group}) ++ geometry_shader ++ @embedFile("shaders/packed_vs.wgsl") ++ @embedFile("shaders/voxel/material_color.wgsl") ++ @embedFile("shaders/shadow_map/sampling.wgsl") ++ @embedFile("shaders/packed_appearance.wgsl") ++ @embedFile("shaders/packed_fs.wgsl");
pub const shadow_shader = std.fmt.comptimePrint("const PACKED_SOURCE_GROUP = {d}u;\n", .{shadow_source_group}) ++ geometry_shader ++ @embedFile("shaders/voxel/material_color.wgsl") ++ @embedFile("shaders/packed_appearance.wgsl") ++ @embedFile("shaders/packed_shadow.wgsl");

pub const Stats = struct {
    sources: usize = 0,
    counts: [category_count]usize = @splat(0),
    gpu_capacity_bytes: usize = 0,
    cpu_capacity_bytes: usize = 0,
    source_builds: u64 = 0,
    source_upload_bytes: u64 = 0,
    source_upload_calls: u64 = 0,
    moved_records: u64 = 0,
    buffer_growths: u64 = 0,
    draw_calls: u64 = 0,
    shadow_draw_calls: u64 = 0,
    vertex_invocations: u64 = 0,
};
const Backref = struct { id: u64, position: u32 };
const Cache = struct { slot: u32, revision: u64, chunk: @Vector(3, i32), indices: [category_count][]u32 };

fn Dense(comptime T: type) type {
    return struct {
        entries: std.ArrayList(T) = .empty,
        refs: std.ArrayList(Backref) = .empty,
        dirty: std.ArrayList(u32) = .empty,
        buffer: zgpu.BufferHandle,
        gpu_capacity: usize = 1,
        replaced: bool = false,
        const Self = @This();

        fn init(gctx: *zgpu.GraphicsContext) Self {
            return .{ .buffer = gctx.createBuffer(.{ .label = "packed dense records", .usage = .{ .storage = true, .copy_dst = true }, .size = @sizeOf(T) }) };
        }
        fn deinit(self: *Self, allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) void {
            gctx.releaseResource(self.buffer);
            self.entries.deinit(allocator);
            self.refs.deinit(allocator);
            self.dirty.deinit(allocator);
        }
        fn reserve(self: *Self, allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, added: usize, removed: usize) !bool {
            const final_count = try std.math.add(usize, self.entries.items.len - removed, added);
            const needed = @max(self.entries.items.len, final_count);
            var limits: wgpu.SupportedLimits = .{};
            if (!gctx.device.getLimits(&limits)) return error.DeviceLimitsUnavailable;
            const max_count = @min(limits.limits.max_buffer_size, limits.limits.max_storage_buffer_binding_size) / @sizeOf(T);
            if (needed > max_count or needed > std.math.maxInt(u32)) return error.PackedCapacityExceeded;
            try self.entries.ensureTotalCapacity(allocator, needed);
            try self.refs.ensureTotalCapacity(allocator, needed);
            // Also reserve enough for allocation-free removal of every live
            // source before the next upload, including repeated swap targets.
            try self.dirty.ensureUnusedCapacity(allocator, 2 * (self.entries.items.len + added) + removed);
            if (needed <= self.gpu_capacity) return false;
            const capacity = @min(max_count, @max(needed, self.gpu_capacity * 2));
            const replacement = gctx.createBuffer(.{ .label = "packed dense records", .usage = .{ .storage = true, .copy_dst = true }, .size = capacity * @sizeOf(T) });
            gctx.releaseResource(self.buffer);
            self.buffer = replacement;
            self.gpu_capacity = @intCast(capacity);
            self.replaced = true;
            return true;
        }
        fn upload(self: *Self, gctx: *zgpu.GraphicsContext, stats: *Stats) void {
            if (self.replaced) {
                if (self.entries.items.len != 0) self.write(gctx, stats, 0, self.entries.items.len);
                self.replaced = false;
            } else if (self.dirty.items.len != 0) {
                std.mem.sort(u32, self.dirty.items, {}, std.sort.asc(u32));
                var start: usize = self.dirty.items[0];
                var end = start + 1;
                for (self.dirty.items[1..]) |index| {
                    if (index <= end) {
                        end = @max(end, @as(usize, index) + 1);
                    } else {
                        self.write(gctx, stats, start, @min(end, self.entries.items.len));
                        start = index;
                        end = start + 1;
                    }
                }
                self.write(gctx, stats, start, @min(end, self.entries.items.len));
            }
            self.dirty.clearRetainingCapacity();
        }
        fn write(self: *Self, gctx: *zgpu.GraphicsContext, stats: *Stats, start: usize, end: usize) void {
            if (start >= end) return;
            gctx.queue.writeBuffer(gctx.lookupResource(self.buffer).?, start * @sizeOf(T), T, self.entries.items[start..end]);
            stats.source_upload_bytes += (end - start) * @sizeOf(T);
            stats.source_upload_calls += 1;
        }
    };
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    sources: std.AutoHashMap(u64, Cache),
    chunks: std.ArrayList([4]i32) = .empty,
    free_chunks: std.ArrayList(u32) = .empty,
    chunk_buffer: zgpu.BufferHandle,
    chunk_gpu_capacity: usize = 1,
    faces: Dense(GPU_Face),
    models: Dense(GPU_Instance),
    packaging: Dense(GPU_Instance),
    pallets: Dense(GPU_Instance),
    markers: Dense(GPU_Marker),
    layout: zgpu.BindGroupLayoutHandle,
    binding: zgpu.BindGroupHandle,
    pipelines: [category_count]zgpu.RenderPipelineHandle,
    shadow_pipelines: [category_count]zgpu.RenderPipelineHandle,
    counters: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, world: *const WorldLayout, layouts: *const BindGroupLayouts) !Renderer {
        const source = try world.shaderSource(allocator, color_shader);
        defer allocator.free(source);
        const shadow_source = try world.shaderSource(allocator, shadow_shader);
        defer allocator.free(shadow_source);
        const layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .read_only_storage, false, 16),
            zgpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, @sizeOf(GPU_Face)),
            zgpu.bufferEntry(2, .{ .vertex = true }, .read_only_storage, false, @sizeOf(GPU_Instance)),
            zgpu.bufferEntry(3, .{ .vertex = true }, .read_only_storage, false, @sizeOf(GPU_Instance)),
            zgpu.bufferEntry(4, .{ .vertex = true }, .read_only_storage, false, @sizeOf(GPU_Instance)),
            zgpu.bufferEntry(5, .{ .vertex = true }, .read_only_storage, false, @sizeOf(GPU_Marker)),
        });
        const pipeline_layout = gctx.createPipelineLayout(&.{ layouts.scene.bind_group_layout_handle, layouts.regular.bind_group_layout_handle, layouts.shadow_map.bind_group_layout_handle, layout });
        defer gctx.releaseResource(pipeline_layout);
        // Shadow casting never samples a shadow map. Keep the geometry group
        // contiguous so no unused sampled-shadow bind group is required while
        // that same texture is the active render target.
        const shadow_pipeline_layout = gctx.createPipelineLayout(&.{ layouts.scene.bind_group_layout_handle, layouts.regular.bind_group_layout_handle, layout });
        defer gctx.releaseResource(shadow_pipeline_layout);
        const module = zgpu.createWgslShaderModule(gctx.device, source.ptr, "packed cargo");
        defer module.release();
        const shadow_module = zgpu.createWgslShaderModule(gctx.device, shadow_source.ptr, "packed cargo shadows");
        defer shadow_module.release();
        var pipelines: [category_count]zgpu.RenderPipelineHandle = undefined;
        var shadows: [category_count]zgpu.RenderPipelineHandle = undefined;
        const shadow_targets = [_]wgpu.ColorTargetState{.{ .format = .r32_float }};
        for (entry_points, 0..) |entry, i| {
            const primitive = wgpu.PrimitiveState{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = if (i == 2) .none else .back };
            pipelines[i] = gctx.createRenderPipeline(pipeline_layout, .{ .label = "packed cargo", .primitive = primitive, .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less }, .vertex = .{ .module = module, .entry_point = entry }, .fragment = &.{ .module = module, .entry_point = "main", .targets = &targets, .target_count = targets.len } });
            shadows[i] = gctx.createRenderPipeline(shadow_pipeline_layout, .{ .label = "packed cargo shadow", .primitive = primitive, .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less }, .vertex = .{ .module = shadow_module, .entry_point = entry }, .fragment = &.{ .module = shadow_module, .entry_point = "main", .targets = &shadow_targets, .target_count = shadow_targets.len } });
        }
        var result: Renderer = .{ .allocator = allocator, .sources = .init(allocator), .chunk_buffer = gctx.createBuffer(.{ .label = "packed source chunks", .usage = .{ .storage = true, .copy_dst = true }, .size = 16 }), .faces = .init(gctx), .models = .init(gctx), .packaging = .init(gctx), .pallets = .init(gctx), .markers = .init(gctx), .layout = layout, .binding = undefined, .pipelines = pipelines, .shadow_pipelines = shadows };
        result.binding = result.createBinding(gctx);
        return result;
    }

    fn createBinding(self: *Renderer, gctx: *zgpu.GraphicsContext) zgpu.BindGroupHandle {
        return gctx.createBindGroup(self.layout, &.{
            .{ .binding = 0, .buffer_handle = self.chunk_buffer, .size = self.chunk_gpu_capacity * 16 },
            .{ .binding = 1, .buffer_handle = self.faces.buffer, .size = self.faces.gpu_capacity * @sizeOf(GPU_Face) },
            .{ .binding = 2, .buffer_handle = self.models.buffer, .size = self.models.gpu_capacity * @sizeOf(GPU_Instance) },
            .{ .binding = 3, .buffer_handle = self.packaging.buffer, .size = self.packaging.gpu_capacity * @sizeOf(GPU_Instance) },
            .{ .binding = 4, .buffer_handle = self.pallets.buffer, .size = self.pallets.gpu_capacity * @sizeOf(GPU_Instance) },
            .{ .binding = 5, .buffer_handle = self.markers.buffer, .size = self.markers.gpu_capacity * @sizeOf(GPU_Marker) },
        });
    }

    pub fn deinit(self: *Renderer, gctx: *zgpu.GraphicsContext) void {
        self.clear(gctx);
        self.sources.deinit();
        self.chunks.deinit(self.allocator);
        self.free_chunks.deinit(self.allocator);
        gctx.releaseResource(self.binding);
        gctx.releaseResource(self.chunk_buffer);
        gctx.releaseResource(self.layout);
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }) |name| @field(self, name).deinit(self.allocator, gctx);
        for (self.pipelines) |pipeline| gctx.releaseResource(pipeline);
        for (self.shadow_pipelines) |pipeline| gctx.releaseResource(pipeline);
    }

    /// All allocations precede publication. A failure leaves the previous source visible.
    pub fn upsertSource(self: *Renderer, gctx: *zgpu.GraphicsContext, id: u64, source: Source) !void {
        if (self.sources.get(id)) |old| if (old.revision == source.revision and @reduce(.And, old.chunk == source.chunk)) return;
        for (source.faces) |face| if (face.direction >= 6) return error.InvalidPackedFace;
        for (source.models) |model| if (model.material != 14 and model.material != 23) return error.InvalidPackedModel;
        const needed = self.chunks.items.len + @intFromBool(self.sources.get(id) == null and self.free_chunks.items.len == 0);
        var limits: wgpu.SupportedLimits = .{};
        if (!gctx.device.getLimits(&limits)) return error.DeviceLimitsUnavailable;
        const max_chunks = @min(limits.limits.max_buffer_size, limits.limits.max_storage_buffer_binding_size) / 16;
        if (needed > max_chunks or needed > std.math.maxInt(u32)) return error.PackedCapacityExceeded;
        const lengths = [category_count]usize{ source.faces.len, source.models.len, source.packaging.len, source.pallets.len, source.markers.len };
        var indices: [category_count][]u32 = undefined;
        var allocated: usize = 0;
        errdefer for (indices[0..allocated]) |list| self.allocator.free(list);
        for (lengths, 0..) |len, i| {
            indices[i] = try self.allocator.alloc(u32, len);
            allocated += 1;
        }
        try self.sources.ensureUnusedCapacity(1);
        try self.chunks.ensureUnusedCapacity(self.allocator, 1);
        try self.free_chunks.ensureTotalCapacity(self.allocator, self.chunks.items.len + 1);
        var binding_changed = false;
        // Rebuild binding even if a later reserve fails after a buffer replacement.
        defer if (binding_changed) {
            const binding = self.createBinding(gctx);
            gctx.releaseResource(self.binding);
            self.binding = binding;
        };
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }, 0..) |name, i| {
            const removed = if (self.sources.get(id)) |old| old.indices[i].len else 0;
            if (try @field(self, name).reserve(self.allocator, gctx, lengths[i], removed)) {
                binding_changed = true;
                self.counters.buffer_growths += 1;
            }
        }
        if (needed > self.chunk_gpu_capacity) {
            const capacity = @min(max_chunks, @max(needed, self.chunk_gpu_capacity * 2));
            const buffer = gctx.createBuffer(.{ .label = "packed source chunks", .usage = .{ .storage = true, .copy_dst = true }, .size = capacity * 16 });
            gctx.releaseResource(self.chunk_buffer);
            self.chunk_buffer = buffer;
            self.chunk_gpu_capacity = capacity;
            binding_changed = true;
            self.counters.buffer_growths += 1;
            if (self.chunks.items.len > 0) {
                gctx.queue.writeBuffer(gctx.lookupResource(buffer).?, 0, [4]i32, self.chunks.items);
                self.counters.source_upload_bytes += self.chunks.items.len * 16;
                self.counters.source_upload_calls += 1;
            }
        }
        const entry = self.sources.getOrPutAssumeCapacity(id);
        const slot = if (entry.found_existing) entry.value_ptr.slot else self.free_chunks.pop() orelse slot: {
            const result: u32 = @intCast(self.chunks.items.len);
            self.chunks.appendAssumeCapacity(.{ 0, 0, 0, 0 });
            break :slot result;
        };
        if (entry.found_existing) self.removeRecords(entry.value_ptr);
        entry.value_ptr.* = .{ .slot = slot, .revision = source.revision, .chunk = source.chunk, .indices = indices };
        self.chunks.items[slot] = .{ source.chunk[0], source.chunk[1], source.chunk[2], 0 };
        gctx.queue.writeBuffer(gctx.lookupResource(self.chunk_buffer).?, @as(usize, slot) * 16, [4]i32, self.chunks.items[slot..][0..1]);
        self.counters.source_upload_bytes += 16;
        self.counters.source_upload_calls += 1;
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }, 0..) |name, category| {
            const batch = &@field(self, name);
            for (@field(source, name), 0..) |input, position| {
                const index: u32 = @intCast(batch.entries.items.len);
                const record = if (category == 0) GPU_Face{ .local = input.local, .material = input.material, .direction = input.direction, .owner = slot } else if (category == 4) GPU_Marker{ .local = input.local, .material = input.material, .disabled = input.disabled, .owner = slot } else GPU_Instance{ .local = input.local, .material = input.material, .owner = slot };
                batch.entries.appendAssumeCapacity(record);
                batch.refs.appendAssumeCapacity(.{ .id = id, .position = @intCast(position) });
                batch.dirty.appendAssumeCapacity(index);
                indices[category][position] = index;
            }
        }
        self.counters.source_builds += 1;
    }

    fn removeRecords(self: *Renderer, cache: *Cache) void {
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }, 0..) |name, category| {
            const allocation = cache.indices[category];
            const batch = &@field(self, name);
            while (cache.indices[category].len > 0) {
                const index = cache.indices[category][cache.indices[category].len - 1];
                cache.indices[category] = cache.indices[category][0 .. cache.indices[category].len - 1];
                _ = batch.entries.swapRemove(index);
                _ = batch.refs.swapRemove(index);
                if (index < batch.entries.items.len) {
                    const moved = batch.refs.items[index];
                    self.sources.getPtr(moved.id).?.indices[category][moved.position] = index;
                    // Removing a source cannot fail. Existing dirty capacity was
                    // reserved for every record when that source was inserted.
                    batch.dirty.appendAssumeCapacity(index);
                    self.counters.moved_records += 1;
                }
            }
            self.allocator.free(allocation);
        }
    }

    pub fn removeSource(self: *Renderer, gctx: *zgpu.GraphicsContext, id: u64) void {
        _ = gctx;
        const cache = self.sources.getPtr(id) orelse return;
        const slot = cache.slot;
        self.removeRecords(cache);
        self.free_chunks.appendAssumeCapacity(slot);
        _ = self.sources.remove(id);
    }
    pub fn clear(self: *Renderer, gctx: *zgpu.GraphicsContext) void {
        _ = gctx;
        var iterator = self.sources.valueIterator();
        while (iterator.next()) |cache| for (cache.indices) |list| self.allocator.free(list);
        self.sources.clearRetainingCapacity();
        self.chunks.clearRetainingCapacity();
        self.free_chunks.clearRetainingCapacity();
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }) |name| {
            @field(self, name).entries.clearRetainingCapacity();
            @field(self, name).refs.clearRetainingCapacity();
            @field(self, name).dirty.clearRetainingCapacity();
        }
    }
    pub fn sourceCount(self: *const Renderer) usize {
        return self.sources.count();
    }
    pub fn stats(self: *const Renderer) Stats {
        var result = self.counters;
        result.sources = self.sourceCount();
        result.gpu_capacity_bytes = self.chunk_gpu_capacity * 16;
        result.cpu_capacity_bytes = self.chunks.capacity * 16 + self.free_chunks.capacity * @sizeOf(u32);
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }, 0..) |name, i| {
            const batch = &@field(self, name);
            const T = std.meta.Child(@TypeOf(batch.entries.items));
            result.counts[i] = batch.entries.items.len;
            result.gpu_capacity_bytes += batch.gpu_capacity * @sizeOf(T);
            result.cpu_capacity_bytes += batch.entries.capacity * @sizeOf(T) + batch.refs.capacity * @sizeOf(Backref) + batch.dirty.capacity * @sizeOf(u32) + batch.entries.items.len * @sizeOf(u32);
        }
        result.cpu_capacity_bytes += self.sources.capacity() * (@sizeOf(u64) + @sizeOf(Cache) + 1);
        return result;
    }
    /// Upload once before any scene pass; shadow and color share the same source.
    pub fn upload(self: *Renderer, gctx: *zgpu.GraphicsContext) void {
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }) |name| @field(self, name).upload(gctx, &self.counters);
    }
    /// Caller supplies scene/atlas groups0..1 and the sampled-light group2 only
    /// for color rendering. All retained sources draw together; there is no
    /// camera-facing index or side grouping.
    pub fn draw(self: *Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, shadow: bool) void {
        inline for (.{ "faces", "models", "packaging", "pallets", "markers" }, 0..) |name, i| {
            // Flat advisory icons do not cast shadows onto their own pallet.
            const count: u32 = @intCast(@field(self, name).entries.items.len);
            if (count != 0 and (!shadow or i != 4)) {
                pass.setPipeline(gctx.lookupResource(if (shadow) self.shadow_pipelines[i] else self.pipelines[i]).?);
                pass.setBindGroup(if (shadow) shadow_source_group else color_source_group, gctx.lookupResource(self.binding).?, &.{});
                pass.draw(vertex_counts[i], count, 0, 0);
                if (shadow) self.counters.shadow_draw_calls += 1 else self.counters.draw_calls += 1;
                self.counters.vertex_invocations += @as(u64, vertex_counts[i]) * count;
            }
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(Face) == 20 and @sizeOf(Instance) == 16 and @sizeOf(Marker) == 20);
    std.debug.assert(@sizeOf(GPU_Face) == 24 and @sizeOf(GPU_Instance) == 20 and @sizeOf(GPU_Marker) == 24);
}
