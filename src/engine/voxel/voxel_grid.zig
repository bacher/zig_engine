const ChunkCoords = @import("../world_math.zig").ChunkCoords;
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const GPUBuffer = @import("../types.zig").GPUBuffer;

const VOXEL_GRID_SLOT_COUNT = @import("./voxel_consts.zig").VOXEL_GRID_SLOT_COUNT;
const VOXEL_GRID_SLOT_SIZE = @import("./voxel_consts.zig").VOXEL_GRID_SLOT_SIZE;
const VOXEL_GRID_BUFFER_SIZE = @import("./voxel_consts.zig").VOXEL_GRID_BUFFER_SIZE;
const MAX_SPAN_SIZE_EXPONENT = @import("./voxel_consts.zig").MAX_SPAN_SIZE_EXPONENT;
const calculateDataSlotSizeLevel = @import("./voxel_utils.zig").calculateDataSlotSizeLevel;
const GPU_ChunkInfo = @import("./voxel_chunk.zig").GPU_ChunkInfo;
const VoxelChunk = @import("./voxel_chunk.zig").VoxelChunk;
const VoxelChunkUpload = @import("./voxel_chunk.zig").VoxelChunkUpload;
const Layer = @import("./voxel_chunk.zig").Layer;
const GeometryStamp = @import("./voxel_chunk.zig").GeometryStamp;
const Side = @import("./voxel_chunk.zig").Side;
const GPU_BlockInfo = @import("./voxel_chunk.zig").GPU_BlockInfo;
const DynamicSlotBufferManager = @import("./DynamicSlotBufferManager.zig").DynamicSlotBufferManager;
const SlotBufferManager = @import("./SlotBufferManager.zig").SlotBufferManager;
const custom = @import("custom_block.zig");

comptime {
    std.debug.assert(VOXEL_GRID_SLOT_SIZE % @sizeOf(GPU_BlockInfo) == 0);
}

const BLOCKS_PER_SLOT: u32 = VOXEL_GRID_SLOT_SIZE / @sizeOf(GPU_BlockInfo);
const BLOCKS_PER_SLOT_INV: f32 = 1.0 / @as(f32, @floatFromInt(BLOCKS_PER_SLOT));

const ChunkList = std.ArrayList(VoxelChunk);
const ChunkUploadList = std.ArrayList(VoxelChunkUpload);

const SideDataPosition = struct {
    // A six-list prefix can exceed 65,535 even though each packed perspective
    // count/offset remains at most 3 * 16,384 for culled opaque 32³ geometry.
    index: u32,
    count: u16,
};

pub const VoxelGrid = struct {
    pub const Self = @This();

    allocator: std.mem.Allocator,
    chunks: ChunkList = .empty,
    chunks_to_upload: ChunkUploadList = .empty,

    gpu_chunk_info_buffer_manager: SlotBufferManager = .{},
    gpu_chunk_info_buffer: GPUBuffer,

    // block data section:
    gpu_block_buffer_manager: DynamicSlotBufferManager = .{},
    gpu_block_buffer: GPUBuffer,
    gpu_custom_block_buffer: GPUBuffer = undefined,
    custom_block_count: u32 = 0,
    custom_slope_count: u32 = 0,
    custom_dirty: bool = false,
    custom_upload: std.ArrayList(custom.GPU_CustomBlock) = .empty,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) !*Self {
        var gpu_chunk_info_buffer: GPUBuffer = undefined;
        var gpu_block_buffer: GPUBuffer = undefined;

        // chunk info buffer
        {
            const size = VOXEL_GRID_SLOT_COUNT * @sizeOf(GPU_ChunkInfo);

            const handle = gctx.createBuffer(.{
                .usage = .{
                    .copy_dst = true,
                    .storage = true, // TODO: Check if this is needed, or maybe it should be uniform?
                },
                .size = size,
            });

            const buffer = gctx.lookupResource(handle) orelse {
                gctx.destroyResource(handle);
                return error.BufferIsNotReady;
            };

            gpu_chunk_info_buffer = .{
                .handle = handle,
                .buffer = buffer,
                .size = size,
            };
        }

        errdefer gctx.destroyResource(gpu_chunk_info_buffer.handle);

        // block buffer
        {
            const size = VOXEL_GRID_BUFFER_SIZE;

            const handle = gctx.createBuffer(.{
                .usage = .{
                    .copy_dst = true,
                    .storage = true, // TODO: Check if this is needed, or maybe it should be uniform?
                },
                .size = size,
            });

            const buffer = gctx.lookupResource(handle) orelse {
                gctx.destroyResource(handle);
                return error.BufferIsNotReady;
            };

            gpu_block_buffer = .{
                .handle = handle,
                .buffer = buffer,
                .size = size,
            };
        }

        errdefer gctx.destroyResource(gpu_block_buffer.handle);

        const custom_handle = gctx.createBuffer(.{ .usage = .{ .copy_dst = true, .storage = true }, .size = VOXEL_GRID_BUFFER_SIZE });
        errdefer gctx.destroyResource(custom_handle);
        const custom_buffer = gctx.lookupResource(custom_handle) orelse return error.BufferIsNotReady;

        const grid = try allocator.create(Self);
        errdefer allocator.destroy(grid);
        grid.* = Self{
            .allocator = allocator,
            .gpu_chunk_info_buffer = gpu_chunk_info_buffer,
            .gpu_block_buffer = gpu_block_buffer,
            .gpu_custom_block_buffer = .{ .handle = custom_handle, .buffer = custom_buffer, .size = VOXEL_GRID_BUFFER_SIZE },
        };

        try grid.chunks.ensureTotalCapacity(allocator, 1024);
        errdefer grid.chunks.deinit(allocator);
        try grid.chunks_to_upload.ensureTotalCapacity(allocator, 128);

        return grid;
    }

    pub fn deinit(self: *Self, gctx: *zgpu.GraphicsContext) void {
        gctx.destroyResource(self.gpu_block_buffer.handle);
        gctx.destroyResource(self.gpu_chunk_info_buffer.handle);
        gctx.destroyResource(self.gpu_custom_block_buffer.handle);
        self.custom_upload.deinit(self.allocator);

        for (self.chunks.items) |*chunk| chunk.custom_blocks.deinit(self.allocator);
        self.chunks.deinit(self.allocator);

        for (self.chunks_to_upload.items) |*chunk| {
            chunk.chunk_surface_data.deinit(self.allocator);
        }
        self.chunks_to_upload.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn clearChunks(self: *Self) void {
        for (self.chunks.items) |*chunk| chunk.custom_blocks.deinit(self.allocator);
        self.custom_dirty = self.custom_dirty or self.custom_block_count > 0;
        self.custom_block_count = 0;
        self.custom_slope_count = 0;
        for (self.chunks_to_upload.items) |*chunk| {
            chunk.chunk_surface_data.deinit(self.allocator);
        }

        self.chunks.clearRetainingCapacity();
        self.chunks_to_upload.clearRetainingCapacity();

        self.gpu_chunk_info_buffer_manager.clear();
        self.gpu_block_buffer_manager.clear();
    }

    pub fn appendChunk(self: *Self, chunk: VoxelChunkUpload) void {
        self.tryAppendChunk(chunk) catch @panic("OOM");
    }

    /// Takes ownership only after all fallible queue growth has succeeded.
    pub fn tryAppendChunk(self: *Self, chunk: VoxelChunkUpload) !void {
        try self.chunks_to_upload.ensureUnusedCapacity(self.allocator, 1);
        // Superseded CPU jobs never reach the GPU. Keep resident geometry until
        // the complete replacement batch passes capacity/allocation preflight.
        self.removeQueuedLayer(chunk.chunk_coords, chunk.layer);
        self.chunks_to_upload.appendAssumeCapacity(chunk);
    }

    /// Removes a chunk (if it's loaded) from the voxel grid and releases the GPU memory slot.
    pub fn removeChunk(self: *Self, chunk_coords: ChunkCoords) void {
        self.removeChunkLayer(chunk_coords, .terrain);
        self.removeChunkLayer(chunk_coords, .construction);
    }

    pub fn removeChunkLayer(self: *Self, chunk_coords: ChunkCoords, layer: Layer) void {
        self.removeQueuedLayer(chunk_coords, layer);
        self.removeResidentLayer(chunk_coords, layer);
    }

    pub fn cancelPendingChunkLayer(self: *Self, chunk_coords: ChunkCoords, layer: Layer) void {
        self.removeQueuedLayer(chunk_coords, layer);
    }

    fn removeQueuedLayer(self: *Self, chunk_coords: ChunkCoords, layer: Layer) void {
        var queued: usize = 0;
        while (queued < self.chunks_to_upload.items.len) {
            if (self.chunks_to_upload.items[queued].layer == layer and @reduce(.And, self.chunks_to_upload.items[queued].chunk_coords == chunk_coords)) {
                var obsolete = self.chunks_to_upload.orderedRemove(queued);
                obsolete.chunk_surface_data.deinit(self.allocator);
            } else queued += 1;
        }
    }

    fn removeResidentLayer(self: *Self, chunk_coords: ChunkCoords, layer: Layer) void {
        for (self.chunks.items, 0..) |*chunk, i| {
            if (chunk.layer == layer and @reduce(.And, chunk.chunk_origin == chunk_coords)) {
                if (chunk.gpu_residence_info) |info| {
                    self.gpu_chunk_info_buffer_manager.freeBlock(info.chunk_index);
                    self.gpu_block_buffer_manager.freeBlock(info.data_slot_index);
                }

                self.custom_dirty = self.custom_dirty or chunk.custom_blocks.items.len > 0;
                chunk.custom_blocks.deinit(self.allocator);
                _ = self.chunks.swapRemove(i);
                return;
            }
        }
    }

    pub fn installedGeometry(self: *const Self, coords: ChunkCoords, layer: Layer) ?GeometryStamp {
        for (self.chunks.items) |chunk| {
            if (chunk.layer == layer and @reduce(.And, chunk.chunk_origin == coords)) return chunk.geometry_stamp;
        }
        return null;
    }

    /// Discovery-only changes can certify already installed, identical bytes.
    /// Content/surface revisions and subscription incarnation must all still match.
    pub fn certifyInstalledGeometry(self: *Self, coords: ChunkCoords, layer: Layer, stamp: GeometryStamp) bool {
        for (self.chunks.items) |*chunk| {
            if (chunk.layer != layer or !@reduce(.And, chunk.chunk_origin == coords)) continue;
            const installed = chunk.geometry_stamp;
            if (installed.subscription_id != stamp.subscription_id or installed.chunk_revision != stamp.chunk_revision or installed.surface_revision != stamp.surface_revision) return false;
            if (stamp.composition_revision < installed.composition_revision) return false;
            chunk.geometry_stamp = stamp;
            return true;
        }
        return false;
    }

    fn isReplaced(self: *const Self, chunk: VoxelChunk) bool {
        for (self.chunks_to_upload.items) |upload| {
            if (chunk.layer == upload.layer and @reduce(.And, chunk.chunk_origin == upload.chunk_coords)) return true;
        }
        return false;
    }

    /// Simulate the exact allocation sequence, including span fragmentation and rounding,
    /// before writing any part of the frame's uploads. Also usable without a GPU device.
    pub fn hasUploadCapacity(self: *const Self) bool {
        var blocks = self.gpu_block_buffer_manager;
        var chunks = self.gpu_chunk_info_buffer_manager;
        var custom_count: usize = 0;
        for (self.chunks.items) |chunk| {
            if (self.isReplaced(chunk)) {
                if (chunk.gpu_residence_info) |info| {
                    chunks.freeBlock(info.chunk_index);
                    blocks.freeBlock(info.data_slot_index);
                }
            } else custom_count += chunk.custom_blocks.items.len;
        }
        for (self.chunks_to_upload.items) |upload| {
            custom_count += upload.chunk_surface_data.custom_blocks.items.len;
            if (custom_count > VOXEL_GRID_BUFFER_SIZE / @sizeOf(custom.GPU_CustomBlock)) return false;
            var count: usize = 0;
            for (upload.chunk_surface_data.blocks_grouped_by_side) |side| count += side.items.len;
            if (count == 0) continue;
            const level = calculateDataSlotSizeLevel(@as(f32, @floatFromInt(count)) * BLOCKS_PER_SLOT_INV);
            if (level > MAX_SPAN_SIZE_EXPONENT) return false;
            _ = blocks.occupyBlock(.{ .size_exponent = level }) catch return false;
            _ = chunks.occupyBlock() catch return false;
        }
        return true;
    }

    pub fn uploadToGPU(self: *Self, gctx: *zgpu.GraphicsContext) void {
        _ = self.tryUploadToGPU(gctx);
    }

    /// Replacements and their removals take effect together after every bounded
    /// buffer allocation is known to fit. A retry preserves the displayed frame.
    pub fn tryUploadToGPU(self: *Self, gctx: *zgpu.GraphicsContext) bool {
        if (!self.hasUploadCapacity()) return false;
        self.chunks.ensureUnusedCapacity(self.allocator, self.chunks_to_upload.items.len) catch return false;
        const block_buffer = self.gpu_block_buffer.buffer;
        const chunk_info_buffer = self.gpu_chunk_info_buffer.buffer;

        if (self.chunks_to_upload.items.len > 0) {
            std.debug.print("Uploading {} voxel chunks to GPU\n", .{self.chunks_to_upload.items.len});
        }

        for (self.chunks_to_upload.items) |upload_chunk| self.removeResidentLayer(upload_chunk.chunk_coords, upload_chunk.layer);
        for (self.chunks_to_upload.items) |*upload_chunk| {
            self.custom_dirty = self.custom_dirty or upload_chunk.chunk_surface_data.custom_blocks.items.len > 0;
            var total_data_size_total: usize = 0;
            for (upload_chunk.chunk_surface_data.blocks_grouped_by_side) |side| {
                total_data_size_total += side.items.len;
            }

            if (total_data_size_total == 0) {
                self.chunks.appendAssumeCapacity(.{ .chunk_origin = upload_chunk.chunk_coords, .layer = upload_chunk.layer, .geometry_stamp = upload_chunk.geometry_stamp, .custom_blocks = upload_chunk.chunk_surface_data.custom_blocks });
                upload_chunk.chunk_surface_data.custom_blocks = .empty;
                continue;
            }

            const data_slot_size_level: u8 = calculateDataSlotSizeLevel(
                @as(f32, @floatFromInt(total_data_size_total)) * BLOCKS_PER_SLOT_INV,
            );

            if (data_slot_size_level > MAX_SPAN_SIZE_EXPONENT) {
                @panic("Slot size level is too high");
            }

            const data_slot_index = self.gpu_block_buffer_manager.occupyBlock(.{
                .size_exponent = data_slot_size_level,
            }) catch @panic("Not enough space in the block data buffer");

            var chunk_info: GPU_ChunkInfo = .{
                .view_side_data_indices = undefined,
                .chunk_origin = upload_chunk.chunk_coords,
                .data_slot_index = data_slot_index,
            };

            var total_data_size: u32 = 0;
            var side_data_indices: [6]SideDataPosition = @splat(.{ .index = 0, .count = 0 });
            for (upload_chunk.chunk_surface_data.blocks_grouped_by_side, 0..) |side, side_index| {
                if (side.items.len > 0) {
                    const data_index = chunk_info.data_slot_index * BLOCKS_PER_SLOT + total_data_size;
                    side_data_indices[side_index] = .{
                        .index = total_data_size,
                        .count = @intCast(side.items.len),
                    };

                    gctx.queue.writeBuffer(
                        block_buffer,
                        data_index * @sizeOf(GPU_BlockInfo),
                        GPU_BlockInfo,
                        side.items,
                    );

                    total_data_size += @intCast(side.items.len);
                }
            }

            const perspective_data = convertSideDataIndicesIntoPerspectiveIndices(
                side_data_indices,
            );

            chunk_info.view_side_data_indices = perspective_data.view_side_data_indices;

            var chunk_inner_data: VoxelChunk = .{
                .chunk_origin = upload_chunk.chunk_coords,
                .layer = upload_chunk.layer,
                .geometry_stamp = upload_chunk.geometry_stamp,
                .gpu_residence_info = null,
                .custom_blocks = upload_chunk.chunk_surface_data.custom_blocks,
            };
            upload_chunk.chunk_surface_data.custom_blocks = .empty;

            if (total_data_size > 0) {
                const chunk_index = self.gpu_chunk_info_buffer_manager.occupyBlock() catch
                    @panic("Not enough space in the chunk info buffer");

                gctx.queue.writeBuffer(
                    chunk_info_buffer,
                    chunk_index * @sizeOf(GPU_ChunkInfo),
                    GPU_ChunkInfo,
                    &.{chunk_info},
                );

                chunk_inner_data.gpu_residence_info = .{
                    .faces_count_per_view = perspective_data.faces_count_per_view,
                    .chunk_index = chunk_index,
                    .data_slot_index = data_slot_index,
                    .data_slot_size_level = data_slot_size_level,
                };
            }

            self.chunks.appendAssumeCapacity(chunk_inner_data);
        }

        // deinit all chunk side data and clear the upload list
        for (self.chunks_to_upload.items) |*chunk| {
            chunk.chunk_surface_data.deinit(self.allocator);
        }
        self.chunks_to_upload.clearRetainingCapacity();
        self.uploadCustomBlocks(gctx);
        return true;
    }

    /// Removals still reach the GPU when ordinary uploads are held by capacity pressure.
    pub fn uploadCustomBlocks(self: *Self, gctx: *zgpu.GraphicsContext) void {
        if (!self.prepareCustomBlocks()) return;
        if (self.custom_block_count > 0) gctx.queue.writeBuffer(self.gpu_custom_block_buffer.buffer, 0, custom.GPU_CustomBlock, self.custom_upload.items);
    }

    fn prepareCustomBlocks(self: *Self) bool {
        if (!self.custom_dirty) return false;
        self.custom_upload.clearRetainingCapacity();
        self.custom_slope_count = 0;
        for (self.chunks.items) |chunk| for (chunk.custom_blocks.items) |block| {
            const slope = if (block.shape == .slope) block.shape.slope else null;
            self.custom_upload.append(self.allocator, .{
                .chunk_origin = chunk.chunk_origin,
                .direction = if (slope) |s| @intFromEnum(s.downhill) else 0,
                .local_origin = .{ @floatFromInt(block.coords[0]), @floatFromInt(block.coords[1]), @floatFromInt(block.coords[2]) },
                .adaptive = @intFromBool(slope == null),
                .high = if (slope) |s| @floatCast(s.high) else 1,
                .low = if (slope) |s| @floatCast(s.low) else 1,
            }) catch @panic("OOM");
            // Keep formed sections first so they retain their 36-vertex draw.
            if (slope != null) {
                std.mem.swap(custom.GPU_CustomBlock, &self.custom_upload.items[self.custom_slope_count], &self.custom_upload.items[self.custom_upload.items.len - 1]);
                self.custom_slope_count += 1;
            }
        };
        self.custom_block_count = @intCast(self.custom_upload.items.len);
        self.custom_dirty = false;
        return true;
    }

    pub fn drawCustomBlocks(self: *const Self, pass: wgpu.RenderPassEncoder) void {
        if (self.custom_slope_count > 0) pass.draw(custom.slope_vertex_count, self.custom_slope_count, 0, 0);
        const adaptive_count = self.custom_block_count - self.custom_slope_count;
        if (adaptive_count > 0) pass.draw(custom.adaptive_vertex_count, adaptive_count, 0, self.custom_slope_count);
    }
};

// 0 left    -x
// 1 right   +x
// 2 front   -y
// 3 back    +y
// 4 bottom  -z
// 5 top     +z

const INDEXES: [8][3]usize = .{
    .{ 0, 2, 4 },
    .{ 0, 2, 5 },
    .{ 0, 3, 4 },
    .{ 0, 3, 5 },
    .{ 1, 2, 4 },
    .{ 1, 2, 5 },
    .{ 1, 3, 4 },
    .{ 1, 3, 5 },
};

fn convertSideDataIndicesIntoPerspectiveIndices(side_data_indices: [6]SideDataPosition) struct {
    view_side_data_indices: [8][3][2]u16,
    faces_count_per_view: [8]u16,
} {
    var view_side_data_indices: [8][3][2]u16 = undefined;
    var faces_count_per_view: [8]u16 = undefined;

    for (0..8) |i| {
        // Effectively matches to this mapping:
        //   i | x, y, z
        //   --|--------
        //   0 | 0, 2, 4
        //   1 | 0, 2, 5
        //   2 | 0, 3, 4
        //   3 | 0, 3, 5
        //   4 | 1, 2, 4
        //   5 | 1, 2, 5
        //   6 | 1, 3, 4
        //   7 | 1, 3, 5
        const x = i >> 2;
        const y = 2 + ((i >> 1) & 1);
        const z = 4 + (i & 1);

        const faces_count = .{
            side_data_indices[x].count,
            side_data_indices[y].count,
            side_data_indices[z].count,
        };

        const total_faces_count = faces_count[0] + faces_count[1] + faces_count[2];

        view_side_data_indices[i] = .{
            .{
                faces_count[0],
                @intCast(side_data_indices[x].index),
            },
            .{
                faces_count[0] + faces_count[1],
                // Empty directions have no stored range and the shader never reads
                // their offset. Subtracting from their default zero would underflow.
                if (faces_count[1] == 0) 0 else @intCast(side_data_indices[y].index - faces_count[0]),
            },
            .{
                total_faces_count,
                if (faces_count[2] == 0) 0 else @intCast(side_data_indices[z].index - faces_count[0] - faces_count[1]),
            },
        };

        faces_count_per_view[i] = total_faces_count;
    }

    return .{
        .view_side_data_indices = view_side_data_indices,
        .faces_count_per_view = faces_count_per_view,
    };

    // return .{
    //     .{ side_data_indices[1], side_data_indices[2], side_data_indices[4], 0 }, // -x -y -z
    //     .{ side_data_indices[1], side_data_indices[2], side_data_indices[5], 0 }, // +x -y -z
    //     .{ side_data_indices[1], side_data_indices[3], side_data_indices[4], 0 }, // -x +y -z
    //     .{ side_data_indices[1], side_data_indices[3], side_data_indices[5], 0 }, // +x +y -z
    //     .{ side_data_indices[0], side_data_indices[2], side_data_indices[4], 0 }, // -x -y +z
    //     .{ side_data_indices[0], side_data_indices[2], side_data_indices[5], 0 }, // +x -y +z
    //     .{ side_data_indices[0], side_data_indices[3], side_data_indices[4], 0 }, // -x +y +z
    //     .{ side_data_indices[0], side_data_indices[3], side_data_indices[5], 0 }, // +x +y +z
    // };
}

test "perspective offsets address the correct faces for every combination of empty directions" {
    for (0..64) |mask| {
        var positions: [6]SideDataPosition = @splat(.{ .index = 0, .count = 0 });
        var next: u16 = 0;
        for (&positions, 0..) |*position, i| {
            if (mask & (@as(usize, 1) << @intCast(i)) == 0) continue;
            position.* = .{ .index = next, .count = @intCast(i + 1) };
            next += position.count;
        }
        const perspective = convertSideDataIndicesIntoPerspectiveIndices(positions);
        for (INDEXES, 0..) |sides, view| {
            var face_index: u16 = 0;
            for (sides, 0..) |side, range| {
                const entry = positions[side];
                for (0..entry.count) |local| {
                    const shader_offset = perspective.view_side_data_indices[view][range][1];
                    try std.testing.expectEqual(entry.index + local, face_index + shader_offset);
                    face_index += 1;
                }
                try std.testing.expectEqual(face_index, perspective.view_side_data_indices[view][range][0]);
            }
            try std.testing.expectEqual(face_index, perspective.faces_count_per_view[view]);
        }
    }
}

test "maximum opaque checkerboard preserves the packed shader count and offset bounds" {
    var positions: [6]SideDataPosition = undefined;
    for (&positions, 0..) |*position, i| position.* = .{ .index = @intCast(i * 16_384), .count = 16_384 };
    try std.testing.expect(positions[5].index > std.math.maxInt(u16));
    const perspective = convertSideDataIndicesIntoPerspectiveIndices(positions);
    const resident: @import("voxel_chunk.zig").GpuResidenceInfo = .{ .faces_count_per_view = perspective.faces_count_per_view, .chunk_index = 0, .data_slot_index = 0, .data_slot_size_level = 9 };
    for (INDEXES, 0..) |sides, view| {
        try std.testing.expectEqual(@as(u16, 49_152), perspective.faces_count_per_view[view]);
        try std.testing.expectEqual(@as(u32, 294_912), resident.vertexCount(view));
        var first: u32 = 0;
        for (sides, 0..) |side, range| {
            const descriptor = perspective.view_side_data_indices[view][range];
            try std.testing.expectEqual(positions[side].index, first + descriptor[1]);
            first += positions[side].count;
            try std.testing.expectEqual(first, descriptor[0]);
        }
    }
}

test "ordinary chunk changes leave custom uploads clean while resident road removal refreshes draws" {
    const allocator = std.testing.allocator;
    var grid: VoxelGrid = .{ .allocator = allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined, .custom_block_count = 1 };
    defer {
        for (grid.chunks.items) |*chunk| chunk.custom_blocks.deinit(allocator);
        for (grid.chunks_to_upload.items) |*chunk| chunk.chunk_surface_data.deinit(allocator);
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
        grid.custom_upload.deinit(allocator);
    }
    const road_coords: ChunkCoords = .{ 1, 1, 1 };
    var road: VoxelChunk = .{ .chunk_origin = road_coords };
    try road.custom_blocks.append(allocator, .{ .coords = .{ 0, 0, 0 }, .shape = .adaptive });
    try grid.chunks.append(allocator, road);
    grid.appendChunk(.{ .chunk_coords = .{ 2, 1, 1 }, .chunk_surface_data = .{} });
    grid.removeChunk(.{ 2, 1, 1 });
    try grid.chunks.append(allocator, .{ .chunk_origin = .{ 3, 1, 1 } });
    grid.removeChunk(.{ 3, 1, 1 });
    try std.testing.expect(!grid.custom_dirty);
    try std.testing.expectEqual(@as(u32, 1), grid.custom_block_count);
    try std.testing.expect(!grid.prepareCustomBlocks());
    grid.removeChunk(road_coords);
    try std.testing.expect(grid.custom_dirty);
    // With no custom records left, this retires the draws independently of any
    // queued ordinary upload or available GPU face-buffer capacity.
    try std.testing.expect(grid.prepareCustomBlocks());
    try std.testing.expect(!grid.custom_dirty);
    try std.testing.expectEqual(@as(u32, 0), grid.custom_block_count);
}

test "custom uploads group formed and unformed geometry and reset after reversion" {
    const allocator = std.testing.allocator;
    var grid: VoxelGrid = .{ .allocator = allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined, .custom_dirty = true };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
        grid.custom_upload.deinit(allocator);
    }
    for (0..2) |chunk| {
        try grid.chunks.append(allocator, .{ .chunk_origin = .{ @intCast(chunk), 0, 0 } });
        for (0..4) |i| try grid.chunks.items[chunk].custom_blocks.append(allocator, .{
            .coords = .{ @intCast(i), 0, 0 },
            .shape = if (i % 2 == 0) .adaptive else .{ .slope = .{ .downhill = .positive_x, .high = 0.75, .low = 0.5 } },
        });
    }
    try std.testing.expect(grid.prepareCustomBlocks());
    try std.testing.expectEqual(@as(u32, 8), grid.custom_block_count);
    try std.testing.expectEqual(@as(u32, 4), grid.custom_slope_count);
    for (grid.custom_upload.items, 0..) |record, i| {
        try std.testing.expectEqual(@as(u32, @intFromBool(i >= 4)), record.adaptive);
        const x: u32 = @intFromFloat(record.local_origin[0]);
        try std.testing.expectEqual(record.adaptive == 0, x % 2 == 1);
        if (record.adaptive == 0) try std.testing.expectEqual(@as(f32, 0.75), record.high);
    }
    for (grid.chunks.items) |*chunk| for (chunk.custom_blocks.items) |*block| {
        block.shape = .adaptive;
    };
    grid.custom_dirty = true;
    try std.testing.expect(grid.prepareCustomBlocks());
    try std.testing.expectEqual(@as(u32, 0), grid.custom_slope_count);
    try std.testing.expectEqual(@as(u32, 8), grid.custom_block_count);
    grid.clearChunks();
    try std.testing.expectEqual(@as(u32, 0), grid.custom_slope_count);
    try std.testing.expect(grid.prepareCustomBlocks());
    try std.testing.expectEqual(@as(u32, 0), grid.custom_block_count);
}

test "construction and terrain replacements retain displayed layers until installation" {
    const allocator = std.testing.allocator;
    var grid: VoxelGrid = .{ .allocator = allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    const coords: ChunkCoords = .{ 1, 2, 3 };
    try grid.chunks.append(allocator, .{ .chunk_origin = coords, .geometry_stamp = .{ .surface_revision = 1 } });
    try grid.chunks.append(allocator, .{ .chunk_origin = coords, .layer = .construction, .geometry_stamp = .{ .surface_revision = 2 } });
    try grid.tryAppendChunk(.{ .chunk_coords = coords, .chunk_surface_data = .{}, .geometry_stamp = .{ .surface_revision = 3 } });
    try grid.tryAppendChunk(.{ .chunk_coords = coords, .layer = .construction, .chunk_surface_data = .{}, .geometry_stamp = .{ .surface_revision = 4 } });
    try std.testing.expectEqual(@as(u64, 1), grid.installedGeometry(coords, .terrain).?.surface_revision);
    try std.testing.expectEqual(@as(u64, 2), grid.installedGeometry(coords, .construction).?.surface_revision);
    try std.testing.expectEqual(@as(usize, 2), grid.chunks_to_upload.items.len);
    try grid.tryAppendChunk(.{ .chunk_coords = coords, .chunk_surface_data = .{}, .geometry_stamp = .{ .surface_revision = 5 } });
    try std.testing.expectEqual(@as(usize, 2), grid.chunks_to_upload.items.len);
    grid.cancelPendingChunkLayer(coords, .terrain);
    try std.testing.expectEqual(@as(usize, 1), grid.chunks_to_upload.items.len);
    try std.testing.expectEqual(@as(u64, 1), grid.installedGeometry(coords, .terrain).?.surface_revision);
    grid.removeChunkLayer(coords, .terrain);
    try std.testing.expectEqual(null, grid.installedGeometry(coords, .terrain));
    try std.testing.expectEqual(@as(u64, 2), grid.installedGeometry(coords, .construction).?.surface_revision);
}

test "construction upload capacity failure keeps resident display and queued work" {
    const allocator = std.testing.allocator;
    var grid: VoxelGrid = .{ .allocator = allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    for (0..VOXEL_GRID_SLOT_COUNT / (1 << MAX_SPAN_SIZE_EXPONENT)) |_| _ = try grid.gpu_block_buffer_manager.occupyBlock(.{ .size_exponent = MAX_SPAN_SIZE_EXPONENT });
    for (0..SlotBufferManager.SLOT_COUNT) |_| _ = try grid.gpu_chunk_info_buffer_manager.occupyBlock();
    const coords: ChunkCoords = .{ 1, 2, 3 };
    try grid.chunks.append(allocator, .{
        .chunk_origin = coords,
        .geometry_stamp = .{ .surface_revision = 1 },
        .gpu_residence_info = .{ .faces_count_per_view = @splat(0), .chunk_index = 0, .data_slot_index = 0, .data_slot_size_level = MAX_SPAN_SIZE_EXPONENT },
    });
    var surface: @import("voxel_chunk.zig").ChunkSurfaceData = .{};
    for (&surface.blocks_grouped_by_side) |*side| {
        try side.resize(allocator, 16_384);
        @memset(side.items, .{ .coords = .{ 1, 1, 1 }, .block_type = .stone });
    }
    try grid.tryAppendChunk(.{ .chunk_coords = coords, .layer = .construction, .chunk_surface_data = surface });
    try std.testing.expect(!grid.hasUploadCapacity());
    try std.testing.expect(!grid.tryUploadToGPU(undefined));
    try std.testing.expectEqual(@as(u64, 1), grid.installedGeometry(coords, .terrain).?.surface_revision);
    try std.testing.expectEqual(@as(usize, 1), grid.chunks_to_upload.items.len);
    grid.chunks_to_upload.items[0].layer = .terrain;
    try std.testing.expect(grid.hasUploadCapacity());
    try std.testing.expectEqual(@as(u64, 1), grid.installedGeometry(coords, .terrain).?.surface_revision);
}
