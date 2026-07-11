const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const GPUBuffer = @import("./types.zig").GPUBuffer;
const VoxelChunk = @import("./voxel_chunk.zig").VoxelChunk;
const ChunkSideInfo = @import("./voxel_chunk.zig").ChunkSideInfo;
const Side = @import("./voxel_chunk.zig").Side;
const BlockInfo = @import("./voxel_chunk.zig").BlockInfo;

pub const VOXEL_GRID_SLOT_SIZE = 1024;
pub const VOXEL_GRID_SLOT_COUNT = 1024;
pub const VOXEL_GRID_BUFFER_SIZE = VOXEL_GRID_SLOT_SIZE * VOXEL_GRID_SLOT_COUNT;

const ChunkList = std.ArrayList(VoxelChunk);

pub const VoxelGrid = struct {
    pub const Self = @This();

    allocator: std.mem.Allocator,
    chunks: ChunkList = .empty,

    gpu_chunk_info_buffer: GPUBuffer,
    gpu_block_buffer: GPUBuffer,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) *Self {
        var gpu_chunk_info_buffer: GPUBuffer = undefined;
        var gpu_block_buffer: GPUBuffer = undefined;

        // chunk info buffer
        {
            const size = VOXEL_GRID_SLOT_COUNT * @sizeOf(ChunkSideInfo);

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

        var chunk = VoxelChunk.init(.{ 0, 0, 0 });
        chunk.loadTestData(allocator);
        grid.chunks.appendAssumeCapacity(chunk);

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

    pub fn uploadToGPU(self: *Self, gctx: *zgpu.GraphicsContext) void {
        const block_buffer = self.gpu_block_buffer.buffer;
        const chunk_info_buffer = self.gpu_chunk_info_buffer.buffer;

        for (self.chunks.items) |chunk| {
            for (chunk.blocks_grouped_by_side, 0..) |side, side_index| {
                if (side.items.len > 0) {
                    const chunk_side_info: ChunkSideInfo = .{
                        .chunk_origin = chunk.chunk_origin,
                        .side = @enumFromInt(side_index),
                    };

                    gctx.queue.writeBuffer(chunk_info_buffer, 0, ChunkSideInfo, &.{chunk_side_info});
                    gctx.queue.writeBuffer(block_buffer, 0, BlockInfo, side.items);
                }
            }
        }
    }
};
