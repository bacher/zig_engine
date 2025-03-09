const std = @import("std");
const gltf_loader = @import("gltf_loader");

const OutputStruct = gltf_loader.ModelBuffer([3]f32);

pub const QuadData = struct {
    data: [][3]f32,
    buffer: []align(4) u8,

    pub fn initUpRightQuad(allocator: std.mem.Allocator) !QuadData {
        const buffer = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 18);

        const data = std.mem.bytesAsSlice([3]f32, buffer);

        //  (0,1)           (1,1)
        //     [x]---------[x]
        //      | (1)    *  |
        //      |     *     |
        //      |  *    (2) |
        //     [x]---------[x]
        //  (0,0)           (1,0)
        //
        // arangement - couter clock wise

        // 1st triangle
        data[0] = .{ 0, 0, 0 };
        data[1] = .{ 1, 1, 0 };
        data[2] = .{ 0, 1, 0 };

        // 2nd triangle
        data[3] = .{ 0, 0, 0 };
        data[4] = .{ 1, 0, 0 };
        data[5] = .{ 1, 1, 0 };

        return .{
            .data = data,
            .buffer = buffer,
        };
    }

    pub fn initCenteredQuad(allocator: std.mem.Allocator) !QuadData {
        const buffer = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 18);

        const data = std.mem.bytesAsSlice([3]f32, buffer);

        // (-0.5,0.5)   (0.5,0.5)
        //     [x]---------[x]
        //      | (1)    *  |
        //      |     *     |
        //      |  *    (2) |
        //     [x]---------[x]
        // (-0.5,-0.5)   (0.5,-0.5)
        //
        // arangement - couter clock wise

        // 1st triangle
        data[0] = .{ -0.5, -0.5, -0.5 };
        data[1] = .{ 0.5, 0.5, -0.5 };
        data[2] = .{ -0.5, 0.5, -0.5 };

        // 2nd triangle
        data[3] = .{ -0.5, -0.5, -0.5 };
        data[4] = .{ 0.5, -0.5, -0.5 };
        data[5] = .{ 0.5, 0.5, -0.5 };

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
