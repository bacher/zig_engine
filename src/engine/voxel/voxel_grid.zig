const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const GPUBuffer = @import("../types.zig").GPUBuffer;

const VOXEL_GRID_SLOT_COUNT = @import("./voxel_consts.zig").VOXEL_GRID_SLOT_COUNT;
const VOXEL_GRID_SLOT_SIZE = @import("./voxel_consts.zig").VOXEL_GRID_SLOT_SIZE;
const VOXEL_GRID_BUFFER_SIZE = @import("./voxel_consts.zig").VOXEL_GRID_BUFFER_SIZE;
const MAX_SPAN_SIZE_EXPONENT = @import("./voxel_consts.zig").MAX_SPAN_SIZE_EXPONENT;
const calculateDataSlotSizeLevel = @import("./voxel_utils.zig").calculateDataSlotSizeLevel;
const VoxelChunk = @import("./voxel_chunk.zig").VoxelChunk;
const ChunkInfo = @import("./voxel_chunk.zig").ChunkInfo;
const Side = @import("./voxel_chunk.zig").Side;
const BlockInfo = @import("./voxel_chunk.zig").BlockInfo;
const DynamicSlotBufferManager = @import("./DynamicSlotBufferManager.zig").DynamicSlotBufferManager;
const SlotBufferManager = @import("./SlotBufferManager.zig").SlotBufferManager;

comptime {
    std.debug.assert(VOXEL_GRID_SLOT_SIZE % @sizeOf(BlockInfo) == 0);
}

const BLOCKS_PER_SLOT: u32 = VOXEL_GRID_SLOT_SIZE / @sizeOf(BlockInfo);
const BLOCKS_PER_SLOT_INV: f32 = 1.0 / @as(f32, @floatFromInt(BLOCKS_PER_SLOT));

const ChunkList = std.ArrayList(VoxelChunk);

const SideDataPosition = struct {
    index: u16,
    count: u16,
};

pub const VoxelGrid = struct {
    pub const Self = @This();

    allocator: std.mem.Allocator,
    chunks: ChunkList = .empty,
    chunks_to_upload: ChunkList = .empty,

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
            const size = VOXEL_GRID_SLOT_COUNT * @sizeOf(ChunkInfo);

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

        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);

        for (self.chunks_to_upload.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks_to_upload.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn clearChunks(self: *Self) void {
        for (self.chunks.items) |*chunk| {
            // self.gpu_chunk_info_buffer_manager.freeBlock(chunk.chunk_index);
            // self.gpu_block_buffer_manager.freeBlock(chunk.data_slot_index);
            chunk.deinit(self.allocator);
        }
        for (self.chunks_to_upload.items) |*chunk| {
            chunk.deinit(self.allocator);
        }

        self.chunks.clearRetainingCapacity();
        self.chunks_to_upload.clearRetainingCapacity();

        self.gpu_chunk_info_buffer_manager.clear();
        self.gpu_block_buffer_manager.clear();
    }

    pub fn appendChunk(self: *Self, chunk: VoxelChunk) void {
        self.chunks_to_upload.append(self.allocator, chunk) catch @panic("OOM");
    }

    /// Removes a chunk (if it's loaded) from the voxel grid and releases the GPU memory slot.
    pub fn removeChunk(self: *Self, chunk_coords: [3]u30) void {
        for (self.chunks.items, 0..) |*chunk, i| {
            if (chunk.chunk_origin[0] == chunk_coords[0] and
                chunk.chunk_origin[1] == chunk_coords[1] and
                chunk.chunk_origin[2] == chunk_coords[2])
            {
                self.gpu_chunk_info_buffer_manager.freeBlock(chunk.chunk_index);
                self.gpu_block_buffer_manager.freeBlock(chunk.data_slot_index);
                _ = self.chunks.swapRemove(i);
                chunk.deinit(self.allocator);
                return;
            }
        }
    }

    pub fn uploadToGPU(self: *Self, gctx: *zgpu.GraphicsContext) void {
        const block_buffer = self.gpu_block_buffer.buffer;
        const chunk_info_buffer = self.gpu_chunk_info_buffer.buffer;

        if (self.chunks_to_upload.items.len > 0) {
            std.debug.print("Uploading {} voxel chunks to GPU\n", .{self.chunks_to_upload.items.len});
        }

        for (self.chunks_to_upload.items) |*chunk| {
            var total_data_size_total: usize = 0;
            for (chunk.blocks_grouped_by_side) |side| {
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

            // TODO: rename into GPUChunkInfo
            var chunk_info: ChunkInfo = .{
                .view_side_data_indices = undefined,
                .chunk_origin = .{
                    chunk.chunk_origin[0],
                    chunk.chunk_origin[1],
                    chunk.chunk_origin[2],
                },
                .data_slot_index = data_slot_index,
            };

            var total_data_size: u16 = 0;
            var side_data_indices: [6]SideDataPosition = @splat(.{ .index = 0, .count = 0 });
            for (chunk.blocks_grouped_by_side, 0..) |side, side_index| {
                if (side.items.len > 0) {
                    const data_index = chunk_info.data_slot_index * BLOCKS_PER_SLOT + total_data_size;
                    side_data_indices[side_index] = .{
                        .index = total_data_size,
                        .count = @intCast(side.items.len),
                    };

                    gctx.queue.writeBuffer(
                        block_buffer,
                        data_index * @sizeOf(BlockInfo),
                        BlockInfo,
                        side.items,
                    );

                    total_data_size += @intCast(side.items.len);
                }
            }

            const perspective_data = convertSideDataIndicesIntoPerspectiveIndices(
                side_data_indices,
            );
            chunk_info.view_side_data_indices = perspective_data.view_side_data_indices;
            chunk.faces_count_per_view = perspective_data.faces_count_per_view;

            if (total_data_size > 0) {
                const chunk_index = self.gpu_chunk_info_buffer_manager.occupyBlock() catch
                    @panic("Not enough space in the chunk info buffer");

                gctx.queue.writeBuffer(
                    chunk_info_buffer,
                    chunk_index * @sizeOf(ChunkInfo),
                    ChunkInfo,
                    &.{chunk_info},
                );

                chunk.chunk_index = chunk_index;
                chunk.data_slot_index = data_slot_index;
                chunk.data_slot_size_level = data_slot_size_level;
            }

            self.chunks.append(self.allocator, chunk.*) catch @panic("OOM");
        }

        self.chunks_to_upload.clearRetainingCapacity();
    }
};

// 0 top     +z
// 1 bottom  -z
// 2 front   -y
// 3 back    +y
// 4 left    -x
// 5 right   +x

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
        const ind = INDEXES[i];

        const faces_count = .{
            side_data_indices[ind[0]].count,
            side_data_indices[ind[1]].count,
            side_data_indices[ind[2]].count,
        };

        const total_faces_count = faces_count[0] + faces_count[1] + faces_count[2];

        view_side_data_indices[i] = .{
            .{
                faces_count[0],
                side_data_indices[ind[0]].index,
            },
            .{
                faces_count[0] + faces_count[1],
                side_data_indices[ind[1]].index - faces_count[0],
            },
            .{
                total_faces_count,
                side_data_indices[ind[2]].index - faces_count[0] - faces_count[1],
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
