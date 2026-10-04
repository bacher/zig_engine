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
const Side = @import("./voxel_chunk.zig").Side;
const GPU_BlockInfo = @import("./voxel_chunk.zig").GPU_BlockInfo;
const DynamicSlotBufferManager = @import("./DynamicSlotBufferManager.zig").DynamicSlotBufferManager;
const SlotBufferManager = @import("./SlotBufferManager.zig").SlotBufferManager;

comptime {
    std.debug.assert(VOXEL_GRID_SLOT_SIZE % @sizeOf(GPU_BlockInfo) == 0);
}

const BLOCKS_PER_SLOT: u32 = VOXEL_GRID_SLOT_SIZE / @sizeOf(GPU_BlockInfo);
const BLOCKS_PER_SLOT_INV: f32 = 1.0 / @as(f32, @floatFromInt(BLOCKS_PER_SLOT));

const ChunkList = std.ArrayList(VoxelChunk);
const ChunkUploadList = std.ArrayList(VoxelChunkUpload);

const SideDataPosition = struct {
    index: u16,
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

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) *Self {
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

            const buffer = gctx.lookupResource(handle).?;

            gpu_chunk_info_buffer = .{
                .handle = handle,
                .buffer = buffer,
                .size = size,
            };
        }

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

            const buffer = gctx.lookupResource(handle).?;

            gpu_block_buffer = .{
                .handle = handle,
                .buffer = buffer,
                .size = size,
            };
        }

        const grid = allocator.create(Self) catch @panic("OOM");
        grid.* = Self{
            .allocator = allocator,
            .gpu_chunk_info_buffer = gpu_chunk_info_buffer,
            .gpu_block_buffer = gpu_block_buffer,
        };

        grid.chunks.ensureTotalCapacity(allocator, 1024) catch @panic("OOM");
        grid.chunks_to_upload.ensureTotalCapacity(allocator, 128) catch @panic("OOM");

        return grid;
    }

    pub fn deinit(self: *Self, gctx: *zgpu.GraphicsContext) void {
        gctx.destroyResource(self.gpu_block_buffer.handle);
        gctx.destroyResource(self.gpu_chunk_info_buffer.handle);

        self.chunks.deinit(self.allocator);

        for (self.chunks_to_upload.items) |*chunk| {
            chunk.chunk_side_data.deinit(self.allocator);
        }
        self.chunks_to_upload.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn clearChunks(self: *Self) void {
        for (self.chunks_to_upload.items) |*chunk| {
            chunk.chunk_side_data.deinit(self.allocator);
        }

        self.chunks.clearRetainingCapacity();
        self.chunks_to_upload.clearRetainingCapacity();

        self.gpu_chunk_info_buffer_manager.clear();
        self.gpu_block_buffer_manager.clear();
    }

    pub fn appendChunk(self: *Self, chunk: VoxelChunkUpload) void {
        self.chunks_to_upload.append(self.allocator, chunk) catch @panic("OOM");
    }

    /// Removes a chunk (if it's loaded) from the voxel grid and releases the GPU memory slot.
    pub fn removeChunk(self: *Self, chunk_coords: [3]u30) void {
        // Multiple packages can replace a mesh before the frame's upload. Cancel the
        // previous queued ownership as well as any resident geometry.
        var queued: usize = 0;
        while (queued < self.chunks_to_upload.items.len) {
            if (std.mem.eql(u30, &self.chunks_to_upload.items[queued].chunk_coords, &chunk_coords)) {
                var obsolete = self.chunks_to_upload.orderedRemove(queued);
                obsolete.chunk_side_data.deinit(self.allocator);
            } else queued += 1;
        }
        for (self.chunks.items, 0..) |*chunk, i| {
            if (chunk.chunk_origin[0] == chunk_coords[0] and
                chunk.chunk_origin[1] == chunk_coords[1] and
                chunk.chunk_origin[2] == chunk_coords[2])
            {
                if (chunk.gpu_residence_info) |info| {
                    self.gpu_chunk_info_buffer_manager.freeBlock(info.chunk_index);
                    self.gpu_block_buffer_manager.freeBlock(info.data_slot_index);
                }

                _ = self.chunks.swapRemove(i);
                return;
            }
        }
    }

    /// Simulate the exact allocation sequence, including span fragmentation and rounding,
    /// before writing any part of the frame's uploads. Also usable without a GPU device.
    pub fn hasUploadCapacity(self: *const Self) bool {
        var blocks = self.gpu_block_buffer_manager;
        var chunks = self.gpu_chunk_info_buffer_manager;
        for (self.chunks_to_upload.items) |upload| {
            var count: usize = 0;
            for (upload.chunk_side_data.blocks_grouped_by_side) |side| count += side.items.len;
            if (count == 0) continue;
            const level = calculateDataSlotSizeLevel(@as(f32, @floatFromInt(count)) * BLOCKS_PER_SLOT_INV);
            if (level > MAX_SPAN_SIZE_EXPONENT) return false;
            _ = blocks.occupyBlock(.{ .size_exponent = level }) catch return false;
            _ = chunks.occupyBlock() catch return false;
        }
        return true;
    }

    pub fn uploadToGPU(self: *Self, gctx: *zgpu.GraphicsContext) void {
        const block_buffer = self.gpu_block_buffer.buffer;
        const chunk_info_buffer = self.gpu_chunk_info_buffer.buffer;

        if (self.chunks_to_upload.items.len > 0) {
            std.debug.print("Uploading {} voxel chunks to GPU\n", .{self.chunks_to_upload.items.len});
        }

        for (self.chunks_to_upload.items) |*upload_chunk| {
            var total_data_size_total: usize = 0;
            for (upload_chunk.chunk_side_data.blocks_grouped_by_side) |side| {
                total_data_size_total += side.items.len;
            }

            if (total_data_size_total == 0) {
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
                .chunk_origin = .{
                    upload_chunk.chunk_coords[0],
                    upload_chunk.chunk_coords[1],
                    upload_chunk.chunk_coords[2],
                },
                .data_slot_index = data_slot_index,
            };

            var total_data_size: u16 = 0;
            var side_data_indices: [6]SideDataPosition = @splat(.{ .index = 0, .count = 0 });
            for (upload_chunk.chunk_side_data.blocks_grouped_by_side, 0..) |side, side_index| {
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
                .gpu_residence_info = null,
            };

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

            self.chunks.append(self.allocator, chunk_inner_data) catch @panic("OOM");
        }

        // deinit all chunk side data and clear the upload list
        for (self.chunks_to_upload.items) |*chunk| {
            chunk.chunk_side_data.deinit(self.allocator);
        }
        self.chunks_to_upload.clearRetainingCapacity();
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
                side_data_indices[x].index,
            },
            .{
                faces_count[0] + faces_count[1],
                // Empty directions have no stored range and the shader never reads
                // their offset. Subtracting from their default zero would underflow.
                if (faces_count[1] == 0) 0 else side_data_indices[y].index - faces_count[0],
            },
            .{
                total_faces_count,
                if (faces_count[2] == 0) 0 else side_data_indices[z].index - faces_count[0] - faces_count[1],
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
