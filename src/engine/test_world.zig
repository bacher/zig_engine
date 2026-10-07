//! Explicit fixture for coordinate regressions; production has no default layout.
pub const layout = @import("world_layout.zig").WorldLayout.init(.{ .size_in_chunks = .{ 512, 256, 8 }, .wrap_x = true }) catch unreachable;
