const std = @import("std");
const zstbi = @import("zstbi");

pub fn loadTextureData(allocator: std.mem.Allocator, file_path: []const u8) !zstbi.Image {
    const buffer_file_path = try std.fmt.allocPrintZ(allocator, "{s}", .{file_path});
    defer allocator.free(buffer_file_path);

    return try zstbi.Image.loadFromFile(buffer_file_path, 4);
}
