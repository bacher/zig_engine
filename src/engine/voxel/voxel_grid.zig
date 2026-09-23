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

            var chunk_info: ChunkInfo = .{
                .side_data_indices = .{ 0, 0, 0, 0, 0, 0 },
                .chunk_origin = .{
                    chunk.chunk_origin[0],
                    chunk.chunk_origin[1],
                    chunk.chunk_origin[2],
                },
                .data_slot_index = data_slot_index,
            };

            var total_data_size: u16 = 0;
            for (chunk.blocks_grouped_by_side, 0..) |side, side_index| {
                if (side.items.len > 0) {
                    const data_index = chunk_info.data_slot_index * BLOCKS_PER_SLOT + total_data_size;
                    chunk_info.side_data_indices[side_index] = total_data_size;

                    gctx.queue.writeBuffer(
                        block_buffer,
                        data_index * @sizeOf(BlockInfo),
                        BlockInfo,
                        side.items,
                    );

                    total_data_size += @intCast(side.items.len);
                }
            }

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
