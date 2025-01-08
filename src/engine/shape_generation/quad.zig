const std = @import("std");
const gltf_loader = @import("gltf_loader");

const OutputStruct = gltf_loader.ModelBuffer([3]f32);

pub const QuadData = struct {
    data: [][3]f32,
    buffer: []align(4) u8,

    pub fn init(allocator: std.mem.Allocator) !QuadData {
        const buffer = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 18);

        const data = std.mem.bytesAsSlice([3]f32, buffer);

        data[0] = .{ 0, 0, 0 };
        data[1] = .{ 0, 1, 0 };
        data[2] = .{ 1, 0, 0 };
        data[3] = .{ 0, 1, 0 };
        data[4] = .{ 1, 1, 0 };
        data[5] = .{ 1, 0, 0 };

        return .{
            .data = data,
            .buffer = buffer,
        };
    }

    pub fn deinit(data: *QuadData, allocator: std.mem.Allocator) void {
        allocator.free(data.buffer);
        data.buffer = &.{};
        data.data = &.{};
    }
};
