const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const GPUBuffer = @import("./types.zig").GPUBuffer;
const VoxelChunk = @import("./voxel_chunk.zig").VoxelChunk;
const ChunkInfo = @import("./voxel_chunk.zig").ChunkInfo;
const Side = @import("./voxel_chunk.zig").Side;
const BlockInfo = @import("./voxel_chunk.zig").BlockInfo;

pub const VOXEL_GRID_SLOT_SIZE = 1024;
pub const VOXEL_GRID_SLOT_COUNT = 2 * 1024;
pub const VOXEL_GRID_BUFFER_SIZE = VOXEL_GRID_SLOT_SIZE * VOXEL_GRID_SLOT_COUNT;

comptime {
    std.debug.assert(VOXEL_GRID_SLOT_SIZE % @sizeOf(BlockInfo) == 0);
}

const BLOCKS_PER_SLOT: u32 = VOXEL_GRID_SLOT_SIZE / @sizeOf(BlockInfo);
const BLOCKS_PER_SLOT_INV: f32 = 1.0 / @as(f32, @floatFromInt(BLOCKS_PER_SLOT));

const ChunkList = std.ArrayList(VoxelChunk);

const MAX_SLOT_SIZE_LEVEL: u8 = 5;

pub const VoxelGrid = struct {
    pub const Self = @This();

    allocator: std.mem.Allocator,
    chunks: ChunkList = .empty,

    gpu_chunk_info_buffer: GPUBuffer,

    // block data section:
    gpu_block_buffer: GPUBuffer,
    freed_block_slots: [MAX_SLOT_SIZE_LEVEL + 1]std.ArrayList(u32) = .{std.ArrayList(u32).empty} ** (MAX_SLOT_SIZE_LEVEL + 1),
    next_free_block_slot: u32 = 0,

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

        return grid;
    }

    pub fn deinit(self: *Self, gctx: *zgpu.GraphicsContext) void {
        gctx.destroyResource(self.gpu_block_buffer.handle);
        gctx.destroyResource(self.gpu_chunk_info_buffer.handle);

        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn appendChunk(self: *Self, chunk: VoxelChunk) void {
        self.chunks.append(self.allocator, chunk) catch @panic("OOM");
    }

    pub fn uploadToGPU(self: *Self, gctx: *zgpu.GraphicsContext) void {
        const block_buffer = self.gpu_block_buffer.buffer;
        const chunk_info_buffer = self.gpu_chunk_info_buffer.buffer;

        var chunk_index: u32 = 0;

        for (self.chunks.items) |*chunk| {
            var total_data_size: u16 = 0;

            var chunk_info: ChunkInfo = .{
                .side_data_indices = .{ 0, 0, 0, 0, 0, 0 },
                .chunk_origin = chunk.chunk_origin,
                .data_slot_index = @intCast(self.next_free_block_slot), // TODO: remove cast
            };

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
                gctx.queue.writeBuffer(
                    chunk_info_buffer,
                    chunk_index * @sizeOf(ChunkInfo),
                    ChunkInfo,
                    &.{chunk_info},
                );

                const data_slot_size_level: u8 = @intFromFloat(
                    @ceil(
                        std.math.log2(
                            @ceil(
                                @as(f32, @floatFromInt(total_data_size)) * BLOCKS_PER_SLOT_INV,
                            ),
                        ),
                    ),
                );

                if (data_slot_size_level > MAX_SLOT_SIZE_LEVEL) {
                    @panic("Slot size level is too high");
                }

                const occupied_slot_count: u32 = std.math.pow(
                    u32,
                    2,
                    data_slot_size_level,
                );

                chunk.chunk_index = chunk_index;
                chunk.data_slot_index = self.next_free_block_slot;
                chunk.data_slot_size_level = data_slot_size_level;

                self.next_free_block_slot += occupied_slot_count;
                chunk_index += 1;
            }
        }
    }
};
